# Edge TTS 协议研究参考

`protocol-research-20260901.txt` 是本项目早期收集的外部公开技术资料摘录，含多组源码示例，仅用于阅读、历史对照和离线核验，不编译、不作为运行依赖，不执行其中脚本。

- 原文件：`docs/edge_tts_protocol.txt`；2026-11-17 原字节移入本目录，无重复旧路径实体。
- 资料内记录的采集日期：2026-09-01。原材料未提供统一上游 commit/tag，不补造版本身份。
- 固定材料长度：105,320 字节；SHA-256：`817908fa099da4d8d5a40bb32d0253c93b3576b6e5a391aa70ec52789a700004`。
- 主要出处包括 [rany2/edge-tts](https://github.com/rany2/edge-tts)、[wilinz 协议说明](https://gist.github.com/wilinz/13f4bc343754f01c06a90aa9c12e449a)、[oadank/voice-engine](https://github.com/oadank/voice-engine/blob/main/edge-tts.mjs)；各摘录的原 URL 和当时说明保留在文件内。
- 权利与许可：各材料仍由原权利人保留，集合原件未附独立许可文件；不另授许可，不将摘录打包进 APK。
- 当前消费者：[历史资料索引](../../docs/history/README.md)、[来源说明](../../docs/SOURCES.md)。实际实现为 `lib/services/edge_tts.dart`。

`test/fixtures/edge_tts_v126.dart` 是本项目旧版本的可执行测试基线，由 `edge_live_test.dart` 实际调用，保留在测试源码树；它不是需要搬走的纯外部参考项目。其他来源仅需在线链接，未下载第二份仓库；独立本地工程和真正构建依赖均未移动。
