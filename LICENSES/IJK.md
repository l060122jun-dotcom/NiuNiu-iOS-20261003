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
- 精确匹配固定 FFmpeg 源码 `libavutil/dict.c` 的四个 pointer 辅助函数：`av_dict_set_intptr` / `av_dict_ptrtostr` 的 `%p` 参数显式转为 `void *`；`av_dict_get_intptr` / `av_dict_strtoptr` 的整数空值改为 `(uintptr_t)0`，删除未使用变量，`strtoull` 结果显式转为 `uintptr_t`。保留原有十六进制字符串协议，不修改正常 `av_dict_set_int` 或其他函数的指针 NULL，不添加 `-Wno-int-conversion` 等全局错误屏蔽。此修改与 TLS 修改一并保存于对应源码包的 `ffmpeg-source.patch`。
- 更新官方控制器的 FFmpeg 版本匹配常量到 `init-ios.sh` 所指定版本。
- 精确匹配固定 IJK 源码 `IJKAudioKit.m` 的 `-[IJKAudioKit setActive:]`：激活和停用路径返回 `AVAudioSession setActive:error:` 的实际 `BOOL` 结果，保留停用异常捕获和日志，捕获异常时返回 `NO`。不改变函数签名，不全局关闭 `-Wreturn-type`；修改收入对应源码包的 `ijk-modern-apple.patch`。
- 仅针对旧 C 源码的 Apple clang 新诊断取消两类错误提升，没有全局禁用警告或错误。
- 将官方 target 的 `MACH_O_TYPE` 从 staticlib 覆盖为 `mh_dylib`；启用模块，验证 Swift import；FFmpeg 静态库在该动态 IJK framework 内链接。App 嵌入该动态 framework，而不是把 LGPL 库静态并入 App 可执行文件。
- framework 和 App 显式链接 `MediaPlayer.framework`，保留官方导出的 legacy MP wrapper；deprecated API 不等同于 removed API，不以全局关闭诊断掩盖 SDK 不兼容。
- CI 固定 `DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer`，先检查目录存在及实际 `xcodebuild -version`。runner 缺少该安装时明确失败，不自动切换其他 Xcode。
- `tools/verify-ijk.sh` 对新产物和缓存命中运行同一验收：arm64/DYLIB、精确 `@rpath/IJKMediaFramework.framework/IJKMediaFramework` install name、依赖路径白名单、modulemap/公共头、真实 `App/Player.swift` 的 Swift 5 typecheck（覆盖该文件实际调用的 IJK API、enum、notification）。完整 App build 后继续验证 EXECUTE、IJK 动态依赖、`@executable_path/Frameworks` rpath、嵌入二进制和许可文件一致性；IPA staging 目录再次验收。

## 随二进制提供的资料

固定 IJK tracked symlink 共 18 项，FFmpeg/gas-preprocessor 无 symlink。原始 git archive 完整保留；`archive-symlinks.json` 记录全部原始链接元数据。仅 `android/android-ndk-prof`（target 为 `../../../../../../ijkprof/android-ndk-profiler-dummy/jni`）是包外 dangling Android profiler 链接，恢复时不创建、不跟随，并从实际构建源码树 hash 排除；同一精确名单收入 `restore-exclusions.json`，不影响 iOS 构建。其他安全链接照常恢复，尤其 `config/module.sh` 要先恢复原始 symlink 再应用修改。禁止路径穿越、其他外链、重复成员及经 symlink 目录写入；原始归档 hash、完整链接元数据及恢复排除名单均核验。Windows 恢复要求能创建真实 symlink，不将其静默替换为普通文本；git apply 使用 `core.symlinks=true`、`core.autocrlf=false`。

CI 的 `IJK-corresponding-source` artifact 含 `IJK-corresponding-source.tar.gz`，其中包含两个锁定版本的原始源码归档、本地修改 patch、实际 module 配置、`config.h` / `config.mak`、构建脚本、工具链记录及许可声明。IPA 内包含 `IJK-Licenses` 许可全文及声明。

源码包另包含锁定 gas-preprocessor 的原始归档、`REBUILD.md`、共享验证脚本、包文件 SHA-256 清单及实际构建所用 tracked 源码树 SHA-256 清单。验收先检查来源锁、必需文件非空及内容 hash，再从三个原始归档恢复正确目录，对两份 patch 执行 `git apply --check` 和实际应用，逐文件比对恢复树与实际构建源码输入，核对 module 配置。hash 清单用于内容一致性检查，不是数字签名或独立来源认证。包内有本地源码重建步骤，不必下载未知二进制；原始 `config.mak` 的临时路径仅作构建记录，重建时须重新 configure。源码 tree 校验不承诺编译后二进制逐字节相同，也不代替完整 App 源码分发。

以上为构建及静态产物门槛，不是已通过 macOS 构建或真机验收的声明。CI 静态检查不能替代签名真机上的 TLS/HLS 安全验收：有效证书应成功，过期、不可信和域名不匹配证书应失败，playlist、segment 与 AES key 请求均须覆盖；还需验证启动、播放、seek、结束通知及硬解回退。未签名 IPA 不可直接运行。

分发 IPA 时应同时分发该源码包和本项目可重建 App 的源码/构建说明，保留第三方声明，并允许用户为调试 LGPL 库修改而进行逆向工程。动态替换仍需重新签名；不可宣称未签名 IPA 可以直接运行。不得设置禁止合法替换/调试 LGPL 组件的额外条款。源码链接本身不应被视作提供对应源码的替代。

GPL/nonfree 禁用使当前 FFmpeg 配置可以按 LGPL 路径再分发，但并不自动免除版权、专利或应用商店条款的其他义务。正式分发前应复核 LGPL-2.1 第 6 节、签名/替换方式、完整源代码及分发渠道的要求；此处不提供法律保证。
