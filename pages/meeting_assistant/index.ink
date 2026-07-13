<script type="application/json" def>
{
  "navigationBarTitleText": "会议军师"
}
</script>

<script setup>
const SPEECH_LANG = 'zh-CN';
const EMPTY_TRANSCRIPT = '未识别到有效语音，请重试。';
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
    canAnalyze: false,
    isListening: false,
    isAnalyzing: false,
    lastError: '',
  },

  async onLoad() {
    this.session = null;
    this.recognition = null;
    this.finalTranscript = '';
    this.pageActive = true;
    this.operationId = 0;
    await this.checkCapabilities();
  },

  onUnload() {
    this.pageActive = false;
    this.operationId += 1;
    this.disposeRecognition();
    this.destroySession();
  },

  async checkCapabilities() {
    const recognitionAvailable = typeof SpeechRecognition !== 'undefined';
    if (!recognitionAvailable) {
      this.setFailure('SpeechRecognition 不可用');
      return;
    }

    try {
      const availability = await LanguageModel.availability();
      if (!this.pageActive) {
        return;
      }
      if (availability !== 'available') {
        this.setFailure('LanguageModel 不可用');
        return;
      }
      this.setData({
        status: '就绪',
        canAnalyze: true,
        lastError: '',
      });
    } catch (error) {
      this.setFailure(`能力检查失败：${getErrorMessage(error)}`);
    }
  },

  setFailure(message) {
    if (!this.pageActive) {
      return;
    }
    this.setData({
      status: '出错',
      canAnalyze: false,
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

  analyzeNext() {
    if (!this.data.canAnalyze || this.data.isListening || this.data.isAnalyzing) {
      return;
    }

    this.operationId += 1;
    const operationId = this.operationId;
    this.finalTranscript = '';
    this.disposeRecognition();

    const recognition = new SpeechRecognition();
    recognition.lang = SPEECH_LANG;
    recognition.continuous = false;
    recognition.interimResults = true;
    recognition.maxAlternatives = 1;

    recognition.onstart = () => {
      if (!this.isCurrent(operationId)) {
        return;
      }
      this.setData({
        status: '正在聆听',
        transcript: '正在识别…',
        cue: '暂无',
        isListening: true,
        lastError: '',
      });
    };

    recognition.onresult = (event) => {
      if (!this.isCurrent(operationId)) {
        return;
      }
      const result = extractTranscript(event);
      if (result.transcript) {
        this.setData({ transcript: result.transcript });
      }
      if (result.hasFinal && result.transcript) {
        this.finalTranscript = result.transcript;
      }
    };

    recognition.onerror = (event) => {
      if (!this.isCurrent(operationId)) {
        return;
      }
      this.recognition = null;
      this.operationId += 1;
      const message = event && event.message
        ? `${event.error || 'error'}: ${event.message}`
        : '语音识别失败';
      this.setFailure(message);
      this.setData({ canAnalyze: true });
    };

    recognition.onend = async () => {
      if (this.recognition === recognition) {
        this.recognition = null;
      }
      if (!this.isCurrent(operationId)) {
        return;
      }

      const transcript = normalizeText(this.finalTranscript || this.data.transcript);
      this.setData({ isListening: false });
      if (!transcript || transcript === '正在识别…') {
        this.setData({
          status: '就绪',
          transcript: EMPTY_TRANSCRIPT,
          canAnalyze: true,
        });
        return;
      }

      this.setData({ transcript });
      await this.requestCue(operationId, transcript);
    };

    this.recognition = recognition;
    this.setData({
      status: '正在启动识别',
      canAnalyze: false,
      isListening: true,
      lastError: '',
    });

    try {
      recognition.start();
    } catch (error) {
      this.disposeRecognition();
      this.setFailure(`无法启动识别：${getErrorMessage(error)}`);
      this.setData({ canAnalyze: true });
    }
  },

  async requestCue(operationId, transcript) {
    if (!this.isCurrent(operationId) || this.data.isAnalyzing) {
      return;
    }

    this.setData({
      status: '正在分析',
      isAnalyzing: true,
      canAnalyze: false,
      cue: '正在生成提示…',
      lastError: '',
    });

    try {
      const session = await this.ensureSession();
      if (!this.isCurrent(operationId)) {
        return;
      }

      const stream = session.promptStreaming(transcript);
      const chunks = [];
      while (this.isCurrent(operationId)) {
        const result = await stream.read();
        if (result.done) {
          break;
        }
        if (typeof result.value === 'string') {
          chunks.push(result.value);
        }
      }

      if (!this.isCurrent(operationId)) {
        return;
      }
      this.setData({
        status: '就绪',
        cue: formatCue(chunks.join('')),
        isAnalyzing: false,
        canAnalyze: true,
      });
    } catch (error) {
      if (!this.isCurrent(operationId)) {
        return;
      }
      this.setFailure(`分析失败：${getErrorMessage(error)}`);
      this.setData({ canAnalyze: true });
    }
  },

  isCurrent(operationId) {
    return this.pageActive && this.operationId === operationId;
  },

  disposeRecognition() {
    const recognition = this.recognition;
    if (!recognition) {
      return;
    }
    this.recognition = null;
    try {
      recognition.onstart = null;
      recognition.onresult = null;
      recognition.onerror = null;
      recognition.onend = null;
      recognition.abort();
    } catch (_error) {}
  },

  destroySession() {
    const session = this.session;
    this.session = null;
    if (!session) {
      return;
    }
    try {
      session.destroy();
    } catch (_error) {}
  },

  async resetSession() {
    this.operationId += 1;
    this.disposeRecognition();
    this.destroySession();
    this.finalTranscript = '';
    this.setData({
      status: '正在重置',
      transcript: '暂无',
      cue: '暂无',
      canAnalyze: false,
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
      <text class="label">最近一次军师提示</text>
      <text class="cue">{{cue}}</text>
    </view>

    <view class="actions" role="navigation">
      <button class="primary" bindtap="analyzeNext" disabled="{{!canAnalyze}}">
        {{isListening ? '正在聆听' : (isAnalyzing ? '正在分析' : '分析下一段')}}
      </button>
      <button class="secondary" bindtap="resetSession">重置会话</button>
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
