# IJK / FFmpeg 第三方声明与可重建来源

此文件不是对整个 App 的许可证授权，也不替代第三方许可证全文。

## 来源锁定

- IJK：官方 https://github.com/bilibili/ijkplayer ，commit `30eb9441945da795079492041a791c121d2b8206`。
- FFmpeg：官方 IJK 维护仓库 https://github.com/Bilibili/FFmpeg ，由该 IJK 提交的 `init-ios.sh` 指定 tag `ff4.0--ijk0.8.8--20210426--001`。
- 该 tag 的 Git tag object 为 `6ccd5fa770b20547b5eb463fd98ca8560adfe696`，实际 peeled commit 为 `e88b5afbf9ca543a098ede6dd6765ef0e629836d`。构建脚本检查实际 commit，不仅信任可移动的 tag。
- 官方汇编辅助工具 https://github.com/Bilibili/gas-preprocessor 固定 commit `dd811e7a8403ef762e333909c54c24674ee04892`；作为构建工具使用，源码及其原有许可证也收入对应源码包，不将工具本身链接到 App。
- IJK 媒体库主要为 LGPL-2.1-or-later；官方构建脚本含 Apache-2.0 声明。FFmpeg 当前选用 LGPL-2.1-or-later 配置；各文件版权与完整许可，以对应源代码及 `COPYING.LGPLv2.1`、`LICENSE.md` 为准。保留全部上游声明。

## 构建配置及本地修改

`tools/build-ijk.sh` 使用官方 `ios/compile-ffmpeg.sh arm64` → `ios/tools/do-compile-ffmpeg.sh` → 官方 `IJKMediaFramework` Xcode target。没有引入第三方预编译 fork。

- 仅 iPhoneOS arm64、deployment target iOS 16；无模拟器、armv7、armv7s 或 i386 输出。
- 明确 Apple clang / ar / ranlib / SDK；移除 `-fembed-bitcode`，保留 arm64 汇编与 NEON。
- 基于官方 `module-lite.sh`，启用 HLS、crypto、https、tls、Apple SecureTransport；不构建 OpenSSL。
- 禁用 GPL、nonfree、version3；构建后核对 `config.h`，不满足时失败。
- 将 FFmpeg `tls_verify` 默认值改为 1，不关闭证书或域名验证。上层也不应设置 `tls_verify=0`。
- 更新官方控制器的 FFmpeg 版本匹配常量到 `init-ios.sh` 所指定版本。
- 仅针对旧 C 源码的 Apple clang 新诊断取消两类错误提升，没有全局禁用警告或错误。
- 将官方 target 的 `MACH_O_TYPE` 从 staticlib 覆盖为 `mh_dylib`；启用模块，验证 Swift import；FFmpeg 静态库在该动态 IJK framework 内链接。App 嵌入该动态 framework，而不是把 LGPL 库静态并入 App 可执行文件。

## 随二进制提供的资料

CI 的 `IJK-corresponding-source` artifact 含 `IJK-corresponding-source.tar.gz`，其中包含两个锁定版本的原始源码归档、本地修改 patch、实际 module 配置、`config.h` / `config.mak`、构建脚本、工具链记录及许可声明。IPA 内包含 `IJK-Licenses` 许可全文及声明。

分发 IPA 时应同时分发该源码包和本项目可重建 App 的源码/构建说明，保留第三方声明，并允许用户为调试 LGPL 库修改而进行逆向工程。动态替换仍需重新签名；不可宣称未签名 IPA 可以直接运行。不得设置禁止合法替换/调试 LGPL 组件的额外条款。源码链接本身不应被视作提供对应源码的替代。

GPL/nonfree 禁用使当前 FFmpeg 配置可以按 LGPL 路径再分发，但并不自动免除版权、专利或应用商店条款的其他义务。正式分发前应复核 LGPL-2.1 第 6 节、签名/替换方式、完整源代码及分发渠道的要求；此处不提供法律保证。
