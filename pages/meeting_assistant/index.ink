<script type="application/json" def>
{
  "navigationBarTitleText": "会议军师"
}
</script>

<script setup>
const SPEECH_LANG = 'zh-CN';
const EMPTY_TRANSCRIPT = '未识别到有效语音，请重试。';
const TOGGLE_DEBOUNCE_MS = 800;
const EMPTY_RETRY_MS = 450;
const NO_SPEECH_RETRY_MS = 650;
const ERROR_RETRY_MS = 1200;
const ANALYSIS_RESTART_MS = 350;
const MAX_CONSECUTIVE_ASR_ERRORS = 5;
const SYSTEM_PROMPT = `你是智能眼镜中的软件项目会议军师。

请结合本场会议的连续上下文，重点检查：
1. 责任人是否明确
2. 完成时间是否明确
3. 是否使用“尽快、再看看、后续处理”等模糊表述
4. 是否没有回答真正的问题
5. 跨团队依赖是否明确交付人和时间
6. 是否可能影响提测、版本、交付或客户
7. 是否与之前的承诺矛盾
8. 是否只解释原因，没有给出解决计划

输出规则：
- 信息完整时输出 NO_CUE
- 需要提醒时只输出一句中文
- 最多32个汉字
- 不输出分析过程
- 不评价人物态度或动机
- 提示必须是佩戴者可以立即采取的动作`;

const SESSION_OPTIONS = {
  initialPrompts: [
    {
      role: 'system',
      content: SYSTEM_PROMPT,
    },
  ],
};

function getErrorMessage(error) {
  if (!error) {
    return '未知错误';
  }
  if (typeof error === 'string') {
    return error;
  }
  return error.message || error.errMsg || String(error);
}

function normalizeText(value) {
  if (typeof value !== 'string') {
    return '';
  }
  return value.replace(/[`#*>\-]/g, '').replace(/\s+/g, ' ').trim();
}

function extractTranscript(event) {
  const results = event && event.results;
  if (!results || typeof results.length !== 'number') {
    return { transcript: '', hasFinal: false };
  }

  const parts = [];
  let hasFinal = false;
  for (let index = 0; index < results.length; index += 1) {
    const result = results[index];
    const alternative = result && result[0];
    if (alternative && alternative.transcript) {
      parts.push(alternative.transcript);
    }
    if (result && result.isFinal) {
      hasFinal = true;
    }
  }
  return {
    transcript: normalizeText(parts.join('')),
    hasFinal,
  };
}

function formatCue(value) {
  const normalized = normalizeText(value);
  if (!normalized || normalized.toUpperCase() === 'NO_CUE') {
    return 'NO_CUE';
  }

  const firstSentence = normalized.split(/[\u3002！？!?\n]/)[0] || normalized;
  return Array.from(firstSentence).slice(0, 32).join('');
}

export default {
  data: {
    status: '正在检查能力',
    transcript: '暂无',
    cue: '暂无',
    meetingActive: false,
    canStart: false,
    isListening: false,
    isAnalyzing: false,
    lastError: '',
  },

  async onLoad() {
    this.session = null;
    this.recognition = null;
    this.finalTranscript = '';
    this.pageActive = true;
    this.meetingActive = false;
    this.recognitionRunning = false;
    this.analysisRunning = false;
    this.operationId = 0;
    this.restartTimer = null;
    this.consecutiveAsrErrors = 0;
    this.lastToggleAt = 0;
    this.destroySessionWhenIdle = false;
    this.capabilitiesReady = false;
    await this.checkCapabilities();
  },

  async onShow() {
    this.pageActive = true;
    this.meetingActive = false;
    this.recognitionRunning = false;
    this.clearRestartTimer();
    this.setData({
      meetingActive: false,
      isListening: false,
      isAnalyzing: this.analysisRunning,
      canStart: false,
      status: '正在检查能力',
      lastError: '',
    });
    await this.checkCapabilities();
  },

  onHide() {
    console.log('[MeetingAssistant] page hidden');
    this.cleanupPage('hidden');
  },

  onUnload() {
    console.log('[MeetingAssistant] page unloaded');
    this.cleanupPage('unloaded');
  },

  onVoiceWakeup(event) {
    const keyword = event && event.keyword ? event.keyword : '';
    console.log('[MeetingAssistant] voice wakeup', keyword);
    this.toggleMeeting('voice-wakeup');
  },

  async checkCapabilities() {
    const recognitionAvailable = typeof SpeechRecognition !== 'undefined';
    if (!recognitionAvailable) {
      this.capabilitiesReady = false;
      this.setFailure('SpeechRecognition 不可用', false);
      return;
    }

    try {
      const availability = await LanguageModel.availability();
      if (!this.pageActive) {
        return;
      }
      if (availability !== 'available') {
        this.capabilitiesReady = false;
        this.setFailure('LanguageModel 不可用', false);
        return;
      }
      this.capabilitiesReady = true;
      this.setData({
        status: '长按侧键开始',
        canStart: !this.analysisRunning,
        lastError: '',
      });
    } catch (error) {
      this.capabilitiesReady = false;
      this.setFailure(`能力检查失败：${getErrorMessage(error)}`, false);
    }
  },

  setFailure(message, canStart = this.capabilitiesReady) {
    if (!this.pageActive) {
      return;
    }
    this.setData({
      status: '出错',
      canStart,
      isListening: false,
      isAnalyzing: false,
      lastError: message,
    });
  },

  async ensureSession() {
    if (this.session) {
      return this.session;
    }
    this.session = await LanguageModel.create(SESSION_OPTIONS);
    return this.session;
  },

  toggleMeeting(source = 'button') {
    const trigger = typeof source === 'string' ? source : 'button';
    const now = Date.now();
    if (now - this.lastToggleAt < TOGGLE_DEBOUNCE_MS) {
      console.log('[MeetingAssistant] duplicate toggle ignored');
      return;
    }
    this.lastToggleAt = now;

    if (this.meetingActive) {
      this.stopMeeting(trigger);
    } else {
      this.startMeeting(trigger);
    }
  },

  startMeeting(source = 'manual') {
    if (!this.pageActive || !this.capabilitiesReady || this.analysisRunning) {
      return;
    }

    this.clearRestartTimer();
    this.disposeRecognition('start meeting');
    this.destroySession('start new meeting');
    this.operationId += 1;
    const operationId = this.operationId;
    this.meetingActive = true;
    this.recognitionRunning = false;
    this.analysisRunning = false;
    this.consecutiveAsrErrors = 0;
    this.destroySessionWhenIdle = false;
    this.finalTranscript = '';
    this.setData({
      meetingActive: true,
      status: '会议军师已开启',
      transcript: '暂无',
      cue: '暂无',
      canStart: true,
      isListening: false,
      isAnalyzing: false,
      lastError: '',
    });
    console.log('[MeetingAssistant] meeting started', source);
    this.startRecognitionCycle(operationId);
  },

  stopMeeting(reason = 'manual') {
    const wasActive = this.meetingActive;
    this.meetingActive = false;
    this.operationId += 1;
    this.clearRestartTimer();
    this.disposeRecognition(reason);
    this.recognitionRunning = false;
    this.finalTranscript = '';

    if (this.analysisRunning) {
      this.destroySessionWhenIdle = true;
    } else {
      this.destroySession(reason);
      this.destroySessionWhenIdle = false;
    }

    if (this.pageActive) {
      this.setData({
        meetingActive: false,
        status: '会议已停止',
        isListening: false,
        isAnalyzing: this.analysisRunning,
        canStart: this.capabilitiesReady && !this.analysisRunning,
      });
    }
    if (wasActive || reason !== 'manual') {
      console.log(`[MeetingAssistant] meeting stopped: ${reason}`);
    }
  },

  analyzeNext() {
    if (!this.meetingActive) {
      this.startMeeting('analyze-next');
    }
  },

  canRunRecognition(operationId) {
    return (
      this.pageActive &&
      this.meetingActive &&
      this.operationId === operationId &&
      !this.recognitionRunning &&
      !this.analysisRunning &&
      !this.recognition &&
      !this.restartTimer
    );
  },

  startRecognitionCycle(operationId) {
    if (!this.canRunRecognition(operationId)) {
      return;
    }

    this.finalTranscript = '';
    this.recognitionRunning = true;
    let recognition;
    let finished = false;
    const finalParts = [];

    const finish = (reason, error = null) => {
      if (finished) {
        return;
      }
      finished = true;
      this.finishRecognition(operationId, recognition, reason, error);
    };

    try {
      recognition = new SpeechRecognition();
    } catch (error) {
      this.recognitionRunning = false;
      console.error('[MeetingAssistant] ASR error:', error);
      this.handleAsrFailure(operationId, 'start-failed', error);
      return;
    }

    recognition.lang = SPEECH_LANG;
    recognition.continuous = false;
    recognition.interimResults = false;
    recognition.maxAlternatives = 1;

    recognition.onstart = () => {
      if (!this.isRecognitionCurrent(operationId, recognition)) {
        return;
      }
      console.log('[MeetingAssistant] ASR listening');
      this.setData({
        status: '正在聆听',
        isListening: true,
        lastError: '',
      });
    };

    recognition.onresult = (event) => {
      if (!this.isRecognitionCurrent(operationId, recognition)) {
        return;
      }
      const result = extractTranscript(event);
      if (result.transcript && (result.hasFinal || recognition.interimResults === false)) {
        finalParts.push(result.transcript);
        this.finalTranscript = normalizeText(finalParts.join(''));
        this.setData({ transcript: this.finalTranscript });
        console.log('[MeetingAssistant] ASR final:', this.finalTranscript);
      }
    };

    recognition.onerror = (event) => {
      if (!this.isRecognitionCurrent(operationId, recognition)) {
        return;
      }
      console.error('[MeetingAssistant] ASR error:', event);
      finish('error', event);
    };

    recognition.onend = () => {
      console.log('[MeetingAssistant] ASR end');
      finish('end');
    };

    this.recognition = recognition;
    this.setData({
      status: '正在启动识别',
      meetingActive: true,
      isListening: true,
      lastError: '',
    });

    try {
      console.log('[MeetingAssistant] ASR start');
      recognition.start();
    } catch (error) {
      console.error('[MeetingAssistant] ASR error:', error);
      finish('error', { error: 'start-failed', message: getErrorMessage(error) });
    }
  },

  isRecognitionCurrent(operationId, recognition) {
    return (
      this.pageActive &&
      this.meetingActive &&
      this.operationId === operationId &&
      this.recognition === recognition
    );
  },

  finishRecognition(operationId, recognition, reason, error) {
    if (this.recognition === recognition) {
      this.disposeRecognition(`cycle ${reason}`);
    }
    this.recognitionRunning = false;

    if (!this.isMeetingOperation(operationId)) {
      return;
    }

    this.setData({ isListening: false });
    if (reason === 'error') {
      const errorCode = error && error.error ? error.error : 'unknown';
      if (errorCode === 'aborted') {
        this.scheduleNextRecognition(operationId, 'aborted', NO_SPEECH_RETRY_MS);
        return;
      }
      if (errorCode === 'no-speech') {
        this.setData({ status: '未听到语音，继续聆听', lastError: '' });
        this.scheduleNextRecognition(operationId, 'no-speech', NO_SPEECH_RETRY_MS);
        return;
      }
      this.handleAsrFailure(operationId, errorCode, error);
      return;
    }

    const transcript = normalizeText(this.finalTranscript);
    if (!transcript) {
      this.setData({
        status: '未识别到语音，继续聆听',
        transcript: EMPTY_TRANSCRIPT,
      });
      console.log('[MeetingAssistant] ASR empty, retry scheduled');
      this.scheduleNextRecognition(operationId, 'empty', EMPTY_RETRY_MS);
      return;
    }

    this.consecutiveAsrErrors = 0;
    this.setData({ transcript });
    this.requestCue(operationId, transcript);
  },

  handleAsrFailure(operationId, errorCode, error) {
    if (!this.isMeetingOperation(operationId)) {
      return;
    }
    this.consecutiveAsrErrors += 1;
    const message = getErrorMessage(error) || errorCode;
    if (this.consecutiveAsrErrors >= MAX_CONSECUTIVE_ASR_ERRORS) {
      this.stopMeeting('asr-error-limit');
      if (this.pageActive) {
        this.setData({
          status: '识别连续失败，请长按重试',
          lastError: message,
          canStart: this.capabilitiesReady,
        });
      }
      return;
    }
    this.setData({
      status: '识别失败，准备重试',
      lastError: message,
    });
    this.scheduleNextRecognition(operationId, errorCode, ERROR_RETRY_MS);
  },

  scheduleNextRecognition(operationId, reason, delayMs) {
    if (!this.isMeetingOperation(operationId) || this.restartTimer) {
      return;
    }
    console.log(`[MeetingAssistant] ASR restart scheduled: ${reason}`);
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      if (!this.isMeetingOperation(operationId)) {
        return;
      }
      this.startRecognitionCycle(operationId);
    }, delayMs);
  },

  async requestCue(operationId, transcript) {
    if (!this.isMeetingOperation(operationId) || this.analysisRunning || !transcript) {
      return;
    }

    this.analysisRunning = true;
    this.setData({
      status: '正在分析',
      isAnalyzing: true,
      isListening: false,
      lastError: '',
    });

    try {
      const session = await this.ensureSession();
      if (!this.isMeetingOperation(operationId)) {
        return;
      }

      console.log('[MeetingAssistant] prompt start:', transcript);
      const result = await session.prompt(transcript);
      console.log('[MeetingAssistant] prompt completed:', result);

      if (!this.isMeetingOperation(operationId)) {
        return;
      }
      const cue = formatCue(result);
      if (cue === 'NO_CUE') {
        this.setData({ status: '暂无新的提示' });
      } else {
        this.setData({ status: '已生成新提示', cue });
      }
    } catch (error) {
      console.error('[MeetingAssistant] prompt failed:', error);
      if (this.isMeetingOperation(operationId)) {
        this.setData({
          status: '分析失败，继续聆听',
          lastError: getErrorMessage(error),
        });
      }
    } finally {
      this.analysisRunning = false;
      if (this.pageActive) {
        this.setData({ isAnalyzing: false });
      }
      if (this.destroySessionWhenIdle) {
        this.destroySessionWhenIdle = false;
        this.destroySession('analysis idle');
      }
      if (this.isMeetingOperation(operationId)) {
        this.scheduleNextRecognition(operationId, 'analysis-complete', ANALYSIS_RESTART_MS);
      } else if (this.pageActive) {
        this.setData({ canStart: this.capabilitiesReady });
      }
    }
  },

  isMeetingOperation(operationId) {
    return this.pageActive && this.meetingActive && this.operationId === operationId;
  },

  clearRestartTimer() {
    if (!this.restartTimer) {
      return;
    }
    clearTimeout(this.restartTimer);
    this.restartTimer = null;
  },

  disposeRecognition(reason = 'cleanup') {
    const recognition = this.recognition;
    if (!recognition) {
      this.recognitionRunning = false;
      return;
    }
    this.recognition = null;
    this.recognitionRunning = false;
    try {
      recognition.onstart = null;
      recognition.onresult = null;
      recognition.onerror = null;
      recognition.onend = null;
      recognition.abort();
    } catch (_error) {}
    console.log(`[MeetingAssistant] recognition disposed: ${reason}`);
  },

  destroySession(reason = 'cleanup') {
    const session = this.session;
    this.session = null;
    if (!session) {
      return;
    }
    try {
      session.destroy();
    } catch (_error) {}
    console.log(`[MeetingAssistant] session destroyed: ${reason}`);
  },

  cleanupPage(reason) {
    this.pageActive = false;
    this.stopMeeting(reason);
    this.clearRestartTimer();
    this.disposeRecognition(reason);
    if (!this.analysisRunning) {
      this.destroySession(reason);
    }
    console.log(`[MeetingAssistant] cleanup completed: ${reason}`);
  },

  async resetSession() {
    if (this.meetingActive || this.analysisRunning) {
      return;
    }
    this.operationId += 1;
    this.clearRestartTimer();
    this.disposeRecognition('reset');
    this.destroySession('reset');
    this.finalTranscript = '';
    this.setData({
      status: '正在重置',
      transcript: '暂无',
      cue: '暂无',
      meetingActive: false,
      canStart: false,
      isListening: false,
      isAnalyzing: false,
      lastError: '',
    });
    await this.checkCapabilities();
  },
};
</script>

<page>
  <view class="container">
    <view class="page-title">会议军师</view>

    <view class="card status-card">
      <text class="label">状态</text>
      <text class="status">{{status}}</text>
      <text class="error" ink:if="{{lastError}}">{{lastError}}</text>
    </view>

    <view class="card">
      <text class="label">最近一次识别文字</text>
      <text class="content">{{transcript}}</text>
    </view>

    <view class="card cue-card">
      <text class="label">最新提示</text>
      <text class="cue">{{cue}}</text>
    </view>

    <text class="meeting-hint">{{meetingActive ? '长按侧键停止' : '长按侧键开始'}}</text>

    <view class="actions" role="navigation">
      <button class="primary" bindtap="toggleMeeting" disabled="{{!meetingActive && !canStart}}">
        {{meetingActive ? '停止会议' : '开始会议'}}
      </button>
      <button class="secondary" bindtap="resetSession" disabled="{{meetingActive || isAnalyzing}}">重置会话</button>
    </view>
  </view>
</page>

<style>
page {
  background-color: #0b1018;
  color: #f5f7fa;
}

.container {
  display: flex;
  flex-direction: column;
  gap: 14px;
  padding: 18px;
}

.page-title {
  font-size: 28px;
  font-weight: 700;
}

.card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 14px;
  border: 1px solid #344154;
  border-radius: 12px;
  background-color: #151d29;
}

.label {
  color: #9eabbc;
  font-size: 14px;
}

.status {
  color: #73d6a5;
  font-size: 20px;
  font-weight: 600;
}

.content {
  color: #e5eaf0;
  font-size: 18px;
  line-height: 1.5;
}

.cue {
  color: #ffd36a;
  font-size: 22px;
  font-weight: 700;
  line-height: 1.45;
}

.error {
  color: #ff8585;
  font-size: 14px;
}

.meeting-hint {
  color: #9eabbc;
  font-size: 15px;
  text-align: center;
}

.actions {
  display: flex;
  flex-direction: row;
  gap: 12px;
}

button {
  flex: 1;
  min-height: 48px;
  border-radius: 10px;
  font-size: 17px;
}

.primary {
  background-color: #2878ff;
  color: #ffffff;
}

.secondary {
  background-color: #263244;
  color: #e8edf5;
}
</style>
