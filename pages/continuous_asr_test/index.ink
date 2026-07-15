<script type="application/json" def>
{
  "navigationBarTitleText": "Continuous ASR Test"
}
</script>

<script setup>
function getErrorMessage(error) {
  if (!error) {
    return '未知错误';
  }
  if (typeof error === 'string') {
    return error;
  }
  return error.message || error.errMsg || error.error || String(error);
}

function serializeError(event) {
  if (!event) {
    return { error: '', message: '' };
  }
  const details = {};
  Object.keys(event).forEach((key) => {
    const value = event[key];
    if (typeof value !== 'function') {
      details[key] = value;
    }
  });
  if (!Object.prototype.hasOwnProperty.call(details, 'error')) {
    details.error = event.error || '';
  }
  if (!Object.prototype.hasOwnProperty.call(details, 'message')) {
    details.message = event.message || '';
  }
  return details;
}

export default {
  data: {
    status: '长按侧键开始测试',
    finalSegmentCount: 0,
    lastTranscript: '',
    transcripts: [],
    testResult: '等待测试',
    lastError: '',
    testRunning: false,
  },

  onLoad() {
    this.pageActive = true;
    this.recognition = null;
    this.recognitionRunning = false;
    this.testStarted = false;
    this.testFinished = false;
    this.startCallCount = 0;
    this.finalSegmentCount = 0;
    this.finalSegments = [];
    this.processedFinalKeys = new Set();
  },

  onShow() {
    this.pageActive = true;
  },

  onVoiceWakeup(event) {
    console.log('[ContinuousASRTest] voice wakeup', event && event.keyword ? event.keyword : '');
    if (this.testFinished) {
      console.log('[ContinuousASRTest] test finished; reopen the page to test again');
      return;
    }
    if (this.testStarted || this.recognitionRunning || this.recognition) {
      console.log('[ContinuousASRTest] test already running');
      return;
    }
    this.startContinuousTest();
  },

  startContinuousTest() {
    if (
      !this.pageActive ||
      this.recognition ||
      this.recognitionRunning ||
      this.testStarted ||
      this.startCallCount !== 0
    ) {
      if (this.testStarted && !this.testFinished) {
        console.log('[ContinuousASRTest] test already running');
      }
      return;
    }

    if (typeof SpeechRecognition === 'undefined') {
      this.testFinished = true;
      this.setData({
        status: '测试失败',
        testResult: '失败：SpeechRecognition 不可用',
        lastError: 'SpeechRecognition 不可用',
      });
      return;
    }

    const recognition = new SpeechRecognition();
    recognition.lang = 'zh-CN';
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.maxAlternatives = 1;
    this.recognition = recognition;
    this.testStarted = true;

    console.log('[ContinuousASRTest] recognition created');
    console.log('[ContinuousASRTest] continuous:', recognition.continuous);

    recognition.onstart = () => {
      if (!this.isCurrentRecognition(recognition)) {
        return;
      }
      this.recognitionRunning = true;
      this.setData({
        status: '正在持续聆听',
        testRunning: true,
        lastError: '',
      });
      console.log('[ContinuousASRTest] recognition started');
    };

    recognition.onspeechstart = () => {
      if (this.isCurrentRecognition(recognition)) {
        console.log('[ContinuousASRTest] speech started');
      }
    };

    recognition.onspeechend = () => {
      if (this.isCurrentRecognition(recognition)) {
        console.log('[ContinuousASRTest] speech ended');
      }
    };

    recognition.onresult = (event) => {
      if (!this.isCurrentRecognition(recognition) || this.testFinished) {
        return;
      }
      this.handleResultEvent(event);
    };

    recognition.onerror = (event) => {
      const details = serializeError(event);
      console.error('[ContinuousASRTest] recognition error:', details);
      if (this.testFinished || !this.pageActive) {
        return;
      }

      const message = getErrorMessage(event);
      this.testFinished = true;
      this.setData({
        status: '测试失败',
        testResult: '失败：识别发生错误',
        lastError: message,
        testRunning: false,
      });
      this.disposeRecognition(`error: ${event && event.error ? event.error : 'unknown'}`);
    };

    recognition.onend = () => {
      console.log('[ContinuousASRTest] recognition ended');
      console.log({
        startCallCount: this.startCallCount,
        finalSegmentCount: this.finalSegmentCount,
        testFinished: this.testFinished,
        pageActive: this.pageActive,
      });

      if (this.recognition === recognition) {
        this.releaseEndedRecognition(recognition);
      }
      if (!this.pageActive) {
        return;
      }
      if (this.finalSegmentCount >= 3) {
        return;
      }
      if (!this.testFinished) {
        this.testFinished = true;
        this.setData({
          status: '识别提前结束',
          testResult: `失败：continuous ASR 在第${this.finalSegmentCount}段后提前结束`,
          testRunning: false,
        });
        console.error('[ContinuousASRTest] TEST FAILED');
        console.error('[ContinuousASRTest] continuous recognition ended before three final segments');
      }
    };

    this.setData({
      status: '正在启动持续识别',
      finalSegmentCount: 0,
      lastTranscript: '',
      transcripts: [],
      testResult: '等待三段 final 结果',
      lastError: '',
      testRunning: true,
    });

    try {
      this.startCallCount += 1;
      console.log('[ContinuousASRTest] start call count:', this.startCallCount);
      console.log('[ContinuousASRTest] recognition.start requested');
      recognition.start();
    } catch (error) {
      console.error('[ContinuousASRTest] recognition error:', error);
      this.testFinished = true;
      this.setData({
        status: '测试失败',
        testResult: '启动失败',
        lastError: getErrorMessage(error),
        testRunning: false,
      });
      this.disposeRecognition('start-failed');
    }
  },

  handleResultEvent(event) {
    const results = event && event.results ? event.results : null;
    console.log('[ContinuousASRTest] result event', {
      resultIndex: event && typeof event.resultIndex === 'number' ? event.resultIndex : 0,
      resultsLength: results && typeof results.length === 'number' ? results.length : 0,
      finalSegmentCount: this.finalSegmentCount,
    });

    if (!results || typeof results.length !== 'number') {
      return;
    }

    for (let index = 0; index < results.length; index += 1) {
      const result = results[index];
      const alternative = result && result[0];
      const transcript = alternative && alternative.transcript
        ? alternative.transcript.trim()
        : '';
      const confidence = alternative && typeof alternative.confidence === 'number'
        ? alternative.confidence
        : null;
      const isFinal = !!(result && result.isFinal);

      console.log('[ContinuousASRTest] result item:', {
        index,
        isFinal,
        transcript,
        confidence,
      });

      if (!transcript) {
        continue;
      }
      this.setData({ lastTranscript: transcript });
      if (!isFinal) {
        continue;
      }

      const finalKey = `${index}:${transcript}`;
      if (this.processedFinalKeys.has(finalKey)) {
        continue;
      }
      this.processedFinalKeys.add(finalKey);
      this.finalSegments.push(transcript);
      this.finalSegmentCount += 1;
      const recentSegments = this.finalSegments.slice(-3);
      this.setData({
        finalSegmentCount: this.finalSegmentCount,
        lastTranscript: transcript,
        transcripts: recentSegments,
      });
      console.log(`[ContinuousASRTest] final #${this.finalSegmentCount}: ${transcript}`);

      if (this.finalSegmentCount >= 3 && !this.testFinished) {
        this.finishPassedTest();
        return;
      }
    }
  },

  finishPassedTest() {
    this.testFinished = true;
    this.setData({
      status: '三段识别成功',
      testResult: '通过：同一个实例收到三段final结果',
      testRunning: false,
    });
    console.log('[ContinuousASRTest] TEST PASSED');
    console.log('[ContinuousASRTest] one start call received three final segments');
    console.log({
      startCallCount: this.startCallCount,
      finalSegmentCount: this.finalSegmentCount,
      finalSegments: this.finalSegments.slice(),
    });
    this.disposeRecognition('test-passed', true);
  },

  isCurrentRecognition(recognition) {
    return this.pageActive && this.recognition === recognition;
  },

  releaseEndedRecognition(recognition) {
    if (this.recognition !== recognition) {
      return;
    }
    this.recognition = null;
    this.recognitionRunning = false;
    recognition.onstart = null;
    recognition.onspeechstart = null;
    recognition.onspeechend = null;
    recognition.onresult = null;
    recognition.onerror = null;
    recognition.onend = null;
    this.setData({ testRunning: false });
  },

  disposeRecognition(reason, preferStop = false) {
    const recognition = this.recognition;
    if (!recognition) {
      this.recognitionRunning = false;
      return;
    }
    this.recognition = null;
    this.recognitionRunning = false;
    recognition.onstart = null;
    recognition.onspeechstart = null;
    recognition.onspeechend = null;
    recognition.onresult = null;
    recognition.onerror = null;
    recognition.onend = null;
    try {
      if (preferStop && typeof recognition.stop === 'function') {
        recognition.stop();
      } else {
        recognition.abort();
      }
    } catch (error) {
      console.error('[ContinuousASRTest] dispose failed:', error);
    }
    console.log(`[ContinuousASRTest] recognition disposed: ${reason}`);
  },

  onHide() {
    this.pageActive = false;
    this.disposeRecognition('page-hidden');
  },

  onUnload() {
    this.pageActive = false;
    this.disposeRecognition('page-unloaded');
  },
};
</script>

<page>
  <view class="container">
    <view class="header-row">
      <text class="title">Continuous ASR Test</text>
      <text class="count">Final：{{finalSegmentCount}} / 3</text>
    </view>
    <view class="info-row">
      <text class="label">状态</text>
      <text class="value status">{{status}}</text>
    </view>
    <view class="info-row transcript-row">
      <text class="label">最近识别</text>
      <text class="value transcript">{{lastTranscript || '暂无'}}</text>
    </view>
    <view class="info-row">
      <text class="label">结果</text>
      <text class="value result">{{testResult}}</text>
    </view>
    <button class="start-button" bindtap="startContinuousTest" disabled="{{testRunning || testResult !== '等待测试'}}">
      开始测试
    </button>
  </view>
</page>

<style>
page {
  width: 448px;
  height: 150px;
  overflow: hidden;
  background-color: #0b1018;
  color: #f5f7fa;
}

.container {
  display: flex;
  flex-direction: column;
  gap: 4px;
  box-sizing: border-box;
  width: 448px;
  height: 150px;
  padding: 7px 10px;
}

.header-row,
.info-row {
  display: flex;
  flex-direction: row;
  align-items: center;
}

.header-row {
  justify-content: space-between;
}

.title {
  font-size: 19px;
  font-weight: 700;
}

.count {
  color: #73d6a5;
  font-size: 15px;
  font-weight: 600;
}

.label {
  width: 72px;
  color: #9eabbc;
  font-size: 13px;
}

.value {
  flex: 1;
  font-size: 14px;
}

.status {
  color: #73d6a5;
}

.transcript-row {
  min-height: 34px;
  align-items: flex-start;
}

.transcript {
  max-height: 34px;
  overflow: hidden;
  line-height: 17px;
}

.result {
  color: #ffd36a;
}

.start-button {
  align-self: flex-end;
  min-width: 104px;
  min-height: 28px;
  margin-top: -2px;
  border-radius: 7px;
  background-color: #2878ff;
  color: #ffffff;
  font-size: 13px;
}
</style>
