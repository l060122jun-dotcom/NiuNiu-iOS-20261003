# 牛牛视频 iOS 无广告移植

以 Android 1.6.2 的业务协议及功能为依据，使用 SwiftUI / AVFoundation 重写 iOS 客户端。界面独立设计，不是 APK 格式转换。

## 状态

源码正在整合与编译验证。此文档不代表所有功能已经真机验收，不代表所有线路均可用。

## 构建

需要 macOS、Xcode 与 XcodeGen。仓库的 GitHub Actions 自动生成未签名 IPA，不使用签名私钥。

```sh
xcodegen generate
xcodebuild -project NiuNiu.xcodeproj -scheme NiuNiu \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## 个人签名

构建产物需要使用个人签名工具签名后才能安装。签名有效期和设备权限取决于签名方式；不需要把 Apple ID 密码、证书或私钥上传到本仓库。后台下载、PiP、DLNA 等需分别实测，构建成功不能替代真机核验。

## 去广告边界

不引入广告、广告归因或广告设备标识 SDK；不显示开屏、插屏、横幅、信息流、激励广告，不伪造广告观看、积分或会员权益。保留独立的账号、兑换、积分消费与其他非广告业务。源站视频自身内嵌广告不等同于客户端广告 SDK。

## 隐私

会话 token 使用 Keychain。收藏及本地播放记录保存在应用沙盒。协议使用随机持久标识而非系统广告 ID。代码不包含原 APK、完整反编译目录、远端配置密钥或个人签名材料。

## 设计参考

- https://github.com/Dimillian/MovieSwiftUI ：影片封面与内容层级。
- https://github.com/Dimillian/IceCubesApp ：原生导航、搜索、消息结构。
- https://github.com/mikelikesdesign/SwiftUI-experiments ：轻量交互思路。

仅借鉴设计方向；不引入这些项目的 SDK，也不宣称复用了其源代码。
