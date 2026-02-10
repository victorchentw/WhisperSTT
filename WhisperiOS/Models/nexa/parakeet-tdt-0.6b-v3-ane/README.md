# Parakeet-TDT-0.6B v3 (ANE)

## Model Description

**parakeet-tdt-0.6b-v3** is a 600M-parameter multilingual automatic speech recognition (ASR) model from **NVIDIA**.
It extends **parakeet-tdt-0.6b-v2** by moving beyond English-only to support **25 European languages** with automatic language detection.

The model was primarily trained on the **Granary multilingual corpus** and is optimized for both research exploration and production deployment.

This build is integrated with **nexaSDK** and optimized for modern **NPUs**, including **Apple’s Neural Engine (ANE)**, for efficient on-device inference.


## Features

* **Multilingual ASR**: 25 European languages with built-in language detection.
* **Text formatting**: Outputs text with **punctuation and capitalization**.
* **Timestamps**: Provides both word-level and segment-level timestamps.
* **Long audio transcription**:

  * Up to **24 minutes** with full attention (A100 80GB).
  * Up to **3 hours** with local attention.
* **Optimized for NPUs**: Runs efficiently on **Apple ANE**, Qualcomm Hexagon, and other dedicated accelerators.
* **Commercial-friendly**: Released under **CC-BY-4.0 license**.


## Apple Neural Engine (ANE)

The **Apple Neural Engine (ANE)** is a specialized NPU in Apple silicon designed to accelerate AI and ML workloads \[3].
By offloading heavy ASR computations to the ANE, **parakeet-tdt-0.6b-v3** achieves:

* **Lower latency** speech transcription on iPhone, iPad, and Mac.
* **Energy-efficient inference**, extending battery life during real-time ASR tasks.
* **On-device privacy**, keeping voice data local while maintaining production-grade accuracy.


## Supported Languages

Bulgarian (bg), Croatian (hr), Czech (cs), Danish (da), Dutch (nl), English (en), Estonian (et),
Finnish (fi), French (fr), German (de), Greek (el), Hungarian (hu), Italian (it), Latvian (lv),
Lithuanian (lt), Maltese (mt), Polish (pl), Portuguese (pt), Romanian (ro), Slovak (sk),
Slovenian (sl), Spanish (es), Swedish (sv), Russian (ru), Ukrainian (uk)


## Use Cases

* Conversational AI and multilingual chatbots
* Voice assistants and smart devices
* Real-time transcription services
* Subtitles and caption generation
* Voice analytics platforms
* Research in speech technology


## Inputs and Outputs

**Input**

* **Type**: 16kHz audio
* **Formats**: `.wav`, `.mp3`
* **Shape**: 1D mono audio

**Output**

* **Type**: Text string
* **Properties**: Punctuation + capitalization included


## Limitations & Responsible Use

The model may produce transcription errors, particularly with code-switching or noisy input.
Evaluate thoroughly before deploying in sensitive domains (e.g., healthcare, finance, or legal).


## License

* Licensed under the original Parakeet license terms.
* See: [Parakeet Model License](https://huggingface.co/NexaAI/parakeet-tdt-0.6b-v3-NPU/blob/main/LICENSE)


## References

* [Parakeet Project](https://huggingface.co/models?search=parakeet)
* [nexaSDK](https://sdk.nexa.ai)
* [Apple Neural Engine (ANE)](https://apple.fandom.com/wiki/Neural_Engine)


## Support
* For Nexa SDK: [sdk.nexa.ai](https://sdk.nexa.ai)