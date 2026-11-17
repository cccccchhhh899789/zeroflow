# PITFALLS_DEV.md

开发踩坑记录(dev-test skill 维护,新增条目按 `DEV-XXX` 递增编号,勿改已有编号)。

## DEV-001: 本地 xcodebuild 不带 `-allowProvisioningUpdates` 直接 BUILD FAILED
- **Pitfall:** 构建时报 `No profiles ... were found`,BUILD FAILED。
- **Cause:** FinderSync 扩展 target 带 App Group(`8NHN73Q43T.com.zeroflow.app`)与沙盒授权,需要 Xcode 自动生成/更新含该 App Group 的 provisioning profile。
- **Prevention:** 本地构建一律带 `-allowProvisioningUpdates`;无团队证书的环境用 CI 等价命令(`CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`)。

## DEV-002: `-derivedDataPath` 指向无写权限目录直接 BUILD FAILED
- **Pitfall:** 给 `-derivedDataPath` 的目录为只读(如 0644)时,构建直接失败。
- **Cause:** xcodebuild 需要在 derived data 目录写中间产物,无写权限即失败。
- **Prevention:** 换一个可写路径。

## DEV-003: xcodebuild 产物路径不可靠,直接 `cp -R` 得到坏符号链接
- **Pitfall:** Debug 产物可能落在 `build/Build/Intermediates.noindex/ArchiveIntermediates/.../Applications/Zeroflow.app`,用 `cp -R` 复制它得到的是坏符号链接。
- **Cause:** 产物落点不总是确定的。
- **Prevention:** 用 `find <derived>/Build -name "Zeroflow.app"` 定位;复制用 `cp -R -L` 解引用;复制前先 `rm -rf` 目标。

## DEV-004: 新增 target 需手改 pbxproj,改错直接 BUILD FAILED
- **Pitfall:** 以为 `.swift` 文件和 target 一样自动纳入工程,新增 target 时漏配;或手改 pbxproj 出错后构建失败。
- **Cause:** 源文件走 `PBXFileSystemSynchronizedRootGroup` 自动纳入(不要手改 pbxproj 加文件),但 target 本身、Embed App Extensions 阶段、target dependency、FinderSync.framework 链接(App 用于 `FIFinderSyncController.isExtensionEnabled`)都是手工维护的。
- **Prevention:** 新增 `.swift` 文件放对应目录即可;新增/调整 target 才动 pbxproj,改完立即构建验证。当前仅 `FinderSyncExtension/` 一个扩展 target,已配好。

## DEV-005: FinderSync 扩展未沙盒化会被 pkd 静默拒绝
- **Pitfall:** `pluginkit -m` 永远不出现该扩展,`pluginkit -a` 返回 0 却无任何日志,右键菜单不出现。
- **Cause:** pkd(pluginkit)静默拒绝非沙盒的 FinderSync 扩展(`com.apple.security.app-sandbox` 缺失)。
- **Prevention:** 扩展 target 必须保持沙盒授权;排查扩展不可见时先核对 entitlements。

## DEV-006: pkd 进程僵死,新扩展登记不上
- **Pitfall:** 新扩展 `pluginkit -a` 返回 0 但 `pluginkit -m` 查不到,反复登记无效。
- **Cause:** pkd 内存会僵住,僵死的旧实例不响应新插件注册。
- **Prevention:** 登记后查不到就 `killall pkd` 再查;`scripts/install-findersync.sh` 已内置处理。

## DEV-007: LaunchServices 残留旧路径插件记录导致 pkd 拒绝扩展
- **Pitfall:** pkd 解析到无效路径(如 build 目录里的旧 app/appex)而拒绝扩展。
- **Cause:** LS 记录了旧路径的插件(重复构建产物留下的登记),优先于新路径被解析。
- **Prevention:** 先 `lsregister -u` 所有旧路径的 app 及其 appex,再只注册 /Applications;`install-findersync.sh` 已内置处理。

## DEV-008: macOS Sequoia/Tahoe 覆盖安装后 Finder 右键菜单消失(陈旧扩展实例)
- **Pitfall:** app 重建/覆盖安装后,扩展显示已启用(`FIFinderSyncController.isExtensionEnabled` 为 true、设置页绿色),但 Finder 右键菜单不出现;手动关闭再开启一次即恢复。
- **Cause:** pkd 与 Finder 仍持有旧扩展实例;已程序化复现(`pluginkit -e ignore` → `-e use` 的 election 循环)。
- **Prevention:** 主 app 启动自愈走 `Zeroflow/Services/FinderSyncReloader.swift`,设置页有「刷新右键菜单扩展」按钮;安装用 `scripts/install-findersync.sh`(支持 `--reload-only` 仅重载)。

## DEV-009: Finder 右键菜单位置无法调整
- **Pitfall:** 尝试把扩展的右键菜单项放到菜单顶部/中间,无法实现。
- **Cause:** 菜单项被 Finder 硬编码在菜单底部,无 API 可调整位置。
- **Prevention:** 放弃调序,接受固定位置。

## DEV-010: 不要用 `UserDefaults(suiteName:)` 读 App Group
- **Pitfall:** 沙盒扩展里读不到主 app 写入的设置,cfprefsd 报 `Container: (null)`。
- **Cause:** cfprefsd 在沙盒扩展进程里无法解析 App Group suite。
- **Prevention:** 主 app(非沙盒但带 `com.apple.security.application-groups`)与扩展双方直接读写 group container 里的 `finder-sync-settings.plist` 文件(见 `Models/SettingsStore.swift` 与 `FinderSyncExtension/FinderSync.swift`)。

## DEV-011: 沙盒里 `homeDirectoryForCurrentUser` 返回容器目录,扩展不监控任何路径
- **Pitfall:** 直接把 `FileManager.default.homeDirectoryForCurrentUser` 当 `directoryURLs` 会让 Finder 完全不监控用户路径,`menu(for:)` 永不触发。
- **Cause:** 沙盒进程里该 API 返回 `~/Library/Containers/<bundle>/Data`,不是真实家目录。
- **Prevention:** 用 `URL(fileURLWithPath: "/Users/\(NSUserName())")` 拼真实家目录。

## DEV-012: `NSMenuItem.representedObject` 跨 XPC 不保留
- **Pitfall:** 点击菜单动作回调里 `sender` 拿不到自定义 `representedObject`,报 `createFile: invalid sender`。
- **Cause:** FinderSync 菜单项动作跨 XPC 传递,representedObject 不会被保留。
- **Prevention:** 在动作里用 `FIFinderSyncController.default().targetedURL()` / `selectedItemURLs()` 重新推导目标(`targetDirectory()`),不要依赖 sender。

## DEV-013: FinderSync 右键目标目录无写权限
- **Pitfall:** 右键目录里新建文件失败,日志 `deny file-write-create`。
- **Cause:** `files.user-selected.read-write` 权限不覆盖 FinderSync 右键目标。
- **Prevention:** 加 `com.apple.security.temporary-exception.files.home-relative-path.read-write`(值 `["/"]`,覆盖整个家目录;不入 App Store 可接受)。

## DEV-014: 扩展里不能直接执行子进程命令(继承沙盒),需转交主 app 代执行
- **Pitfall:** 扩展里 `Process` 拉起终端/pty 类命令(如 `wezterm start`)EPERM 秒退。
- **Cause:** 子进程继承扩展的沙盒约束。
- **Prevention:** 自定义命令不在扩展执行:扩展把请求写进 group container 的 `finder-command-*.plist` 并广播分布式通知(沙盒发通知不能带 userInfo),由非沙盒主 app `Zeroflow/Services/FinderCommandRunner.swift` 代执行(启动时消化积压请求,超过 30s 的丢弃;扩展侧主 app 未运行时会拉起它)。

## DEV-015: 新 SDK(27.0)下 EventKit/CG/NSScreen 的 API 形态变化
- **Pitfall:** 灵动岛功能首编四处报错:`store.events(from:to:calendars:)` 不存在、`EKCalendar.color` 按 CGColor 用报类型错、`NSScreen.auxiliaryTopLeft/RightArea` 按 non-optional 用报可选错、`CGEvent.keyCode` 属性不存在。
- **Cause:** EventKit 便捷查询只剩谓词版 `events(matching:)`;macOS 上 `EKCalendar.color` 一直是 NSColor(iOS 才是 CGColor);辅助区矩形在新 SDK 声明为可选;CGEvent 键码要走 `getIntegerValueField(.keyboardEventKeycode)`。
- **Prevention:** 遇到系统框架 API 编译错先查本机 SDK 头文件(`/Applications/Xcode.app/.../System/Library/Frameworks/<F>.framework/Headers/*.h`)再改实现,不要凭记忆按 iOS 或旧文档签名写。

## DEV-016: `animator().setFrameOrigin(_:)` 对 NSWindow 无效
- **Pitfall:** 灵动岛面板从刘海后方 12pt 滑入,用 `animator().setFrameOrigin(final)` 做动画,面板最终停在起始位置(比目标高 12pt),像是"贴不到刘海下缘"。
- **Cause:** NSWindow 经 animator 代理可动画的属性只有 frame/alphaValue/bounds 等,`setFrameOrigin:` 不在其中,调用静默无效。
- **Prevention:** 窗口位移动画用 `animator().setFrame(_:display:)`(先 setFrame 到起始位置);或只动画 alphaValue/内容视图 transform。

## DEV-017: 窗口背景液态玻璃/磨砂的边界(macOS 26+)
- **Pitfall:** `CGWindowListCreateImage` 在 macOS 15 已 obsoleted(SDK 15+ 直接编译错误),系统磨砂(NSVisualEffectView)公开 API 不暴露模糊半径;`NSGlassEffectView` 的 `alphaValue` 会连 contentView 内容一起变透明,不能当「背景不透明度」用。
- **Cause:** 液态玻璃透明度只能经 `tintColor` 的 alpha(染色深浅)控制;内容必须嵌 `contentView` 才保证在玻璃内(任意兄弟子视图 z 序无保证)。
- **Prevention:** macOS 26+ 面板背景用 `NSGlassEffectView`(cornerRadius 对齐屏幕圆角,macOS 上无公开 API 查屏幕圆角,取 16);旧系统回退 `NSVisualEffectView(.hudWindow)`。若真需要面板背后区域的模糊快照,须 SCScreenshotManager + `SCContentFilter(display:excludingWindows: [自身 SCWindow])` 整屏捕获后裁剪再 `CIGaussianBlur`(输入先 `clampedToExtent()` 防边缘晕边);SCShareableContent 枚举耗时数百毫秒,需缓存。

## DEV-018: ad-hoc 签名的扩展对 App Group 容器只读,写请求文件 EPERM,「打开终端」静默失效
- **Pitfall:** 「访达右键 → 打开终端」点击毫无反应,而「新建空文件」(纯扩展内动作)正常,极具迷惑性。扩展 os_log 仅报 `submit: failed to write`,底层为 `NSCocoaErrorDomain Code=513 / NSPOSIXErrorDomain Code=1 (EPERM)`;group container 里从未出现 `finder-command-*.plist`,主 app 日志零条 `finderCommand`。GitHub CI 的 ad-hoc 包必现,Team 签名构建正常。
- **Cause:** ad-hoc 签名(`TeamIdentifier=not set`)的沙盒扩展,系统不认可其 `com.apple.security.application-groups` entitlement,沙盒只放行 group container 的**读**、**写**被拒(EPERM)。扩展读设置正常所以菜单/文案都正常,只有「写请求文件」这一步死;非沙盒主 app 不受沙盒中介、读写都正常——这种读写不对称掩盖了问题。Team 签名(真证书)即可放行写,实测无需嵌入 provisioning profile。
- **Prevention:** 涉及 FinderSync 扩展的产物必须 Team 签名(`CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=8NHN73Q43T`)。CI 已加 `Import signing certificate` 步骤从 secrets 导入证书,发 tag 时断言 appex `TeamIdentifier=8NHN73Q43T`;无 secrets 回退 ad-hoc 仅限编译检查(那种包右键命令功能无效)。排障用 `log show --info --predicate 'subsystem == "com.zeroflow.app.finderSync"'`(必须 `--info`,否则只剩 error 级);`CustomCommandRunner.submit` 的失败日志已改为输出真实 NSError + 完整路径(之前只打布尔,排障信息为零)。

## DEV-019: MediaRemote 私有框架在 macOS 15.4+ 的可用读取路径与 JXA 细节
- **Pitfall:** `MRMediaRemoteGetNowPlayingInfo` C 函数在 15.4+ 被封(符号在但回调永不来);legacy `MediaRemote` ObjC 类在 macOS 27 已不存在;JXA 里 NSBundle 调用 `-loadBundle` 报 "not a function"(方法名是 `-load`)。
- **Cause:** Apple 逐步收紧 MediaRemote;唯一仍开放的进程内读取路径是 `MRNowPlayingRequest` 类属性(`localNowPlayingItem`/`localNowPlayingPlayerPath`),对无自动化授权的进程也开放(osascript JXA 与进程内 KVC 均实测可用)。播放控制 `MRMediaRemoteSendCommand` 的 dlsym 符号仍存在。
- **Prevention:** 读取优先进程内 `(NSClassFromString("MRNowPlayingRequest") as AnyObject).value(forKey:)`(KVC 前一律 `responds(to:)` 守卫,未知 key 会抛 ObjC 异常崩溃);类缺失再降级 `osascript -l JavaScript` 子进程(bundle.load 而非 loadBundle,数值字段经 `.js` 转 String 再解析);控制走 dlsym `MRMediaRemoteSendCommand`,Swift block 参数用 `@convention(c)`(命令号 toggle=2/next=4/previous=5)。app 名/图标从 `playerPath.client.displayName/bundleIdentifier` + `NSWorkspace.runningApplications` 取,info dict 不含封面字节。

## DEV-020: IOKit 统计键的 C 宏不进 Swift,host_statistics64 计数要从结构体尺寸算
- **Pitfall:** `kIOBlockStorageDriverStatisticsKey` 等按符号用报 "cannot find in scope";内存采样 count 直接用常量或拍脑袋会返回 KERN_INVALID_ARGUMENT。
- **Cause:** 这些键是 IOKit 头文件里的字符串宏(`#define kIOBlockStorageDriverStatisticsKey "Statistics"`,读/写键为 `"Bytes (Read)"`/`"Bytes (Write)"`),Swift 侧不导入;`HOST_VM_INFO64_COUNT` 也是宏。
- **Prevention:** IOKit 键直接写字符串值(真实值查 SDK 头文件 `IOKit.framework/Headers/storage/IOBlockStorageDriver.h`);`mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)` 自算 count。资源监控数据源速记(macOS 27 实测,全免 root):CPU=host_processor_info 两次 ticks 差值;内存已用=active+inactive+speculative+wired+compressor−purgeable−external(≈活动监视器「内存已用」,≠top 的 PhysMem used=总−free,后者含缓存文件,别拿来对数);网络=sysctl NET_RT_IFLIST2 的 if_data64 逐接口差值(排除 IFT_LOOP);磁盘=IOService("IOBlockStorageDriver") 注册表 "Statistics" 的读写字节差值;GPU=IOAccelerator "PerformanceStatistics" 的 "Device Utilization %"(本机存在,瞬时值无需差分;备用 "GPU Activity(%)")。`swiftc | head` 会因管道 SIGPIPE 杀掉编译器且 `&&` 拿到的是 head 的退出码,验证脚本要重定向到文件再 grep。

## DEV-021: macOS 窗口 frame 弹簧动画无公开 API,需主线程定时器积分实现
- **Pitfall:** 灵动岛面板要做 iPhone 式「从刘海长出/缩回」的弹簧动画,`NSAnimationContext` 只支持贝塞尔 `CAMediaTimingFunction`,`CASpringTimingFunction` 在 macOS 不公开,窗口 frame 无法用系统弹簧曲线动画。
- **Cause:** NSWindow 经 animator() 可动画的属性走 Core Animation 但只暴露贝塞尔曲线;UIKit 语义的弹簧参数(response/dampingFraction)动画必须自己积分。
- **Prevention:** 主线程 120Hz `Timer` 对弹簧微分方程半隐式欧拉积分(k=(2π/response)²,c=2ζ√k)后直接 `setFrame(_:display:)`(dt 远小于稳定域 2/ω 不会发散);打断续接需用各分量当前值与速度重建弹簧、作废旧动画的 completion(否则收起的 orderOut 会在重展开后误触发);Timer 必须加进 `.common` mode,否则面板按钮的事件跟踪期间动画冻结。「先横向后纵向但要连续」的路径感无法靠单弹簧分量参数差做出(各分量同时起跳,前 ~0.3s 都走完大半路程,参数差拉不开视觉差距),必须中途交接:引导段用临界阻尼(ζ=1,无回弹)弹向中间目标,引导分量位移进度达阈值(如 85%)时以当前值/速度重定向到终目标(`NotchSpringAnimator.Handoff`),段间才无停顿无回弹。参考 `NotchPanelView.swift` 的 `NotchSpringAnimator`。

## DEV-022: 窗口弹簧动画里 alpha 走独立快速淡入,会把「生长」动画感知成「从一侧滑入」
- **Pitfall:** 灵动岛面板做「从刘海长出」弹簧动画,frame 用弹簧、alpha 用独立的 0.15s 快速淡入:用户看到的是半透明面板从一侧快速滑到位 + 渐显,完全不是「从刘海逐渐长大」,方向感全错。
- **Cause:** 弹簧位移前 ~15% 时间就走完 85% 路程,独立淡入结束时可变大半已展开;肉眼能捕捉的只剩后段残留位移( leading 边缘扫过),感知成滑入。弹性动画里透明度与几何分开调,时序感知必然错位。
- **Prevention:** 「刘海生长/缩回」动画全程不透明(深色 HUD 起点盖住黑色刘海,出现/消失都无感,形状渐变本身就是全部视觉),透明度完全不参与动画;若别的窗口必须有淡入淡出,alpha 须由几何进度推导而非独立时长,打断时以当前值续接。

## DEV-023: 打断在途窗口动画时,严禁 setContentSize/setFrame 直接改窗口尺寸
- **Pitfall:** 面板「收起弹簧未播完→再次弹出」走打断路径时调用了 `setContentSize`(最终尺寸):窗口几何绕过弹簧直接跳变(尺寸瞬间到位、按原点锚定另一侧瞬移),随后位置再弹簧滑到位 → 用户看到「全尺寸面板从屏幕一侧平移到中间」,与弹簧动画预期完全不符。
- **Cause:** `setContentSize`/`setFrame` 是瞬时几何赋值;打断场景窗口处于中间态,直接改尺寸等于把「在途位移」换成「瞬移 + 平移收尾」。`setContentSize` 还按窗口原点(左下)锚定缩放,另一侧边缘瞬移,平移感更明显。
- **Prevention:** 打断动画只做一件事——弹簧目标重定向(以当前值/速度续接);任何路径都不要在动画在途时用 `setContentSize`/`setFrame` 改尺寸。`present` 的起始定位(setFrame 刘海矩形)只放在「窗口不可见」的全新展开分支。参考 `NotchPanel.present`。

## DEV-024: NSHostingView 经约束/glass.contentView 挂载会把窗口宽高反向钳死
- **Pitfall:** 灵动岛面板弹簧 setFrame 每帧改窗口尺寸,内容却不动:只有原点生效,宽高被「静默锁死」在 SwiftUI 的固定尺寸上,「从刘海生长」退化成全尺寸面板平移。
- **Cause:** 把 `NSHostingView` 赋给 `NSGlassEffectView.contentView` 或对 hosting 用 Auto Layout 约束后,SwiftUI 固定 `.frame` 尺寸会经约束链/玻璃层反向钳制窗口的 contentLayoutGuide,窗口 setFrame 的宽高分量被覆盖。
- **Prevention:** hosting 必须以 `addSubview` + `autoresizingMask = [.width, .height]` 跟随宿主视图,宿主铺满 contentView;绝不能用约束挂载。参考 `NotchPanel.makeContentView`。

## DEV-025: NSView 没有 viewDidChangeBounds 可重写,bounds 变化的回调是 layout()
- **Pitfall:** 想在窗口每帧改尺寸时同步重建 CAShapeLayer 遮罩路径,重写 `viewDidChangeBounds()` 直接编译错 "method does not override any method from its superclass"(AppKit swiftinterface 里根本没有这个方法)。
- **Cause:** 该方法名与 UIView 的直觉混淆;NSView 的几何变化回调就是 `layout()`,bounds 尺寸变化时 AppKit 会触发它。
- **Prevention:** 跟随窗口/容器尺寸的 layer 工作(遮罩路径、子图层 frame)统一放 `override func layout()`;若担心首帧,可在初始化时用已知目标尺寸先算一遍。CAShapeLayer 每帧改 path 记得设 `actions = ["path": NSNull(), ...]` 禁隐式动画,否则遮罩滞后于弹簧。

## DEV-026: layer-backed NSView 的图层坐标系跟随 isFlipped,非 flipped 视图 = y 向上
- **Pitfall:** 手写 CGPath 给 NSView 的 layer 做遮罩(iOS 思维默认左上原点 y 向下),在 macOS 上路径垂直翻转,圆角上下颠倒。
- **Cause:** macOS 图层坐标系不是固定 y 向下:`isGeometryFlipped` 跟随视图的 `isFlipped`(默认 false → 原点左下、y 向上;flipped 视图 → true)。与 UIKit 相反方向的坑。
- **Prevention:** 写路径前先确认宿主视图 isFlipped;非 flipped 视图按 y 向上写(底边在 y=0)。实测方法:`swift` 脚本建 `NSView` + `wantsLayer = true`,打印 `layer?.isGeometryFlipped`(注意 Swift 里是 `isGeometryFlipped` 不是 `geometryFlipped`,后者编译错)。

## DEV-027: 窗口弹簧回弹要锚定尺寸,不能对 origin 做弹簧
- **Pitfall:** 灵动岛面板的展开/收起弹簧把窗口 frame 当 x/y/width/height 四分量独立积分,过冲时 x/y 也在动(且 x 是左边界、y 是下边界),宽度/高度回弹表现为整个窗口一边平移一边变形,用户感知成「整窗回弹/晃动」,而不是「原地放大到 105% 再回弹到 100%」。
- **Cause:** origin 是尺寸的函数(顶边中点固定时 x = centerX - w/2、y = topY - h);对 origin 和尺寸分别积弹簧等于把同一个几何约束拆成两个自由度过冲,二者相位/幅度不一致就产生整体位移。仅把 x/y 阻尼调大(0.90)也消不掉宽度过冲带来的边缘扫动。
- **Prevention:** 位置分量改积「锚点」而非 origin(顶边贴屏幕顶的面板用 centerX/topY,锚点临界阻尼 ζ=1 零回弹),每帧用 `x = centerX - width/2`、`y = topY - height` 反推 frame;尺寸分量保留欠阻尼过冲,窗口就会围绕锚点左右/上下对称外扩再收回,位置全程不动。过冲幅度随交接初速变化,不能直接用 `exp(-πζ/√(1-ζ²))` 推算,应按实际分段交接逻辑跑数值模拟定阻尼比。参考 `NotchPanelView.swift` 的 `NotchSpringAnimator`。

## DEV-028: 灵动岛「面板尺寸随内容自适应」时,测量口径必须与渲染口径一致
- **Pitfall:** 面板尺寸由内容决定后,沿用旧的测量口径(资源卡传 `columnHeight` 把行拉伸到槽高、渲染端 `.frame(maxWidth: .infinity)` 拉伸列宽)会量出「槽高/槽宽」而不是自然尺寸,面板永远缩不回去;卡片 `contentHeight` 若按「不含内边距」传给渲染端,`padding → .frame(height:)` 会让内容比测量值少 20pt 被压扁。
- **Cause:** 同一个 SwiftUI 视图在「测量」与「渲染」两条路径复用,列宽/列高/拉伸开关只是参数——测量时传值等于强制几何,不是「上限」;`.padding().frame(height:)` 的 frame 高度包含 padding。
- **Prevention:** 自然尺寸测量不传拉伸参数(资源行测自然高、列宽用 `naturalColumnWidth(for:)`);渲染列宽取卡片内宽硬值,去掉 `maxWidth: .infinity`;卡片渲染顺序为 `内容 → .frame(height: contentHeight) → .scaleEffect(scale) → .frame(cardW, cardH) → .background(卡片底) → .frame(height: 槽高)`(background/外层 frame 在 scale 之后,缩放只作用于内容、背景始终是卡片框)。`contentHeight` 与测量值同为「含卡片内边距」,缩放系数 = `min(1, cardH / contentHeight)`,宽度方向只重排不缩放。面板宽高 = 卡片 + 可见外边距 + 顶部刘海条,只有屏幕边界(高 −80)兜底;左右留白还要把「遮罩侧墙相对窗口边缘的内缩」算进面板宽(肩弧半径 ∝ 面板宽,需迭代收敛),否则卡片会正好填满可见黑边、看起来没有外边距。`refit` 的比较项必须包含面板/卡片宽高与内容高,否则日程异步加载后尺寸不更新。参考 `NotchPanel.computeLayout` / `NotchContentView.renderedCard`。

## DEV-029: 可见面板按内容改尺寸必须走弹簧,并同步控制器的命中区域
- **Pitfall:** 面板尺寸随内容自适应后,切换模块 / 日程异步加载(refit)需要改窗口尺寸:若直接 `setFrame` 或只换 contentView 不改窗口,会出现尺寸瞬跳(DEV-023 的整块平移感)或内容与黑底不匹配;控制器缓存的 `panelFrameTL` 若不同步,「点击面板外收起 / 移出保活」仍按旧尺寸判定,窄面板外的大片区域会误收起或点不到。
- **Cause:** `panelFrameTL` 只在 present 时写入;窗口尺寸的权威值在弹簧里逐帧变化,而命中判定使用弹簧终点 `targetFrame`。
- **Prevention:** switchModule / refit 后统一走 `applyLayoutFrame`(重建 contentView + `springAnimator.animate(to: 新终 frame)`),并由控制器在调用后 `syncPanelFrame()` 用 `panel.targetFrame` 刷新 `panelFrameTL`;任何可见路径都不得直接 `setFrame`(仅窗口不可见时的首次展开定位可用)。参考 `NotchPanel.applyLayoutFrame` / `NotchHotspotController.syncPanelFrame`。

## DEV-030: 卡片内固定高度的「半块」用 `.frame(height:)` 会静默裁切/溢出
- **Pitfall:** 资源卡按「上下两块等高」排版时,给单元格写死 `.frame(width:height: 88)`;实际内容(环 56 + 两行文字)是 88.x 高,SwiftUI 不裁切也不报错——内容在固定 frame 里居中溢出,压到分隔线/下半块上,而 `fittingSize` 仍是 88,测量脚本看不出问题(只有「只启用主要项」那张卡量出 123 而不是 122 才暴露)。
- **Cause:** 固定高度 frame 只是布局约束,不约束绘制;测量口径与真实内容高被 frame 截断,偏差被掩盖。
- **Prevention:** 等高块用 `.frame(minHeight: X)` 而不是 `.frame(height: X)`:两块仍至少各占半块,内容更高时自然长高、测量同步反映;改完用「只开单项 / 全开」两种组合各量一次高度,差值应符合预期(半块缺失应少一整块的高度)。

## DEV-031: 环形容器 `Circle().stroke` 的描边会溢出 frame
- **Pitfall:** 直接用 `Circle().stroke(lineWidth:)` 画环,描边以路径为中心向内外各占一半,细看环外侧被相邻视图裁掉一条(尤其放在固定 `frame(width:height:)` 的角落或卡片边缘时)。
- **Cause:** `Circle()` 的路径内切于 frame,`stroke` 默认居中描边,半径不足时超出边界。
- **Prevention:** 先 `.inset(by: lineWidth / 2)` 再 `.stroke`(环心文字同理加 `lineWidth` 级内边距),这样描边完整落在 frame 内。参考 `ResourceRing`。

## DEV-032: 资源卡「浮在两主项之间」的次要项要用 ZStack 覆盖,并准备好无留白时的回退
- **Pitfall:** 想把 GPU 小环放进上半块两环之间的空白正中,若把三个格子塞进同一个 `HStack`,主项环会被挤窄(120 → 92),内存副信息「12.4 GB / 32 GB」被迫缩字,主次感也被拉平。
- **Cause:** `HStack` 等分宽度会重新分配主项空间;而「空白」本来就在两格之间,不需要新格子。
- **Prevention:** 主项仍用 `HStack` 等分,次要项作为 `ZStack` 的一层居中覆盖(不占格、主项尺寸不变),尺寸小于主项(GPU 环 34 vs CPU/内存 56)以分层级。只启用一个主项(或没有主项)时中间没有留白,此时必须回退成并排的第二个格子,否则会和主项文字/环重叠;核对重叠要按「垂直区间 × 水平区间」分段看——小环与副信息行不在同一高度带,才允许水平区间相邻。加宽列(`resourcesColumnWidth`)只是给留白与通栏趋势线留余量,不能代替回退分支。

## DEV-033: 无辅助功能权限时无法用合成鼠标事件验证灵动岛,改用测量探针
- **Pitfall:** 想脚本化验证灵动岛资源卡:用 `CGWarpMouseCursorPosition` 把光标移进刘海热区、并 `post` 合成 `mouseMoved`,面板始终不弹出(`Notch: show` 日志为 0),容易误判成布局没生效。
- **Cause:** 光标 warp 不产生事件;合成事件需要辅助功能授权,CLI 进程未授权时 `post` 静默丢弃(listen-only tap 本身仍能装,`tap installed OK` 不代表能注入事件)。
- **Prevention:** 布局/尺寸类改动不要依赖截图或鼠标模拟:用 `NotchContentView.measureCardSize(module:columnWidth:compact:model:)` 在临时 env 探针里跑组合(全开 / 只开主项 / 主项+GPU / 只开 GPU / 无 GPU),常规与 compact 各量一次,核对卡片宽高与「少一整块」的差值;探针用完立即删除(会改 `notchResourceItems` 的设置,必须临时改再还原)。

## DEV-034: 非激活灵动岛上的双指滑动不能靠子视图 scrollWheel,要用 NSEvent local monitor
- **Pitfall:** 想在 `NotchShapeContainerView`(或面板视图)重写 `scrollWheel` 做双指左右切换,手指落在卡片(日历日程是 SwiftUI `ScrollView`)上时事件被 SwiftUI 先吃掉,容器收不到,表现为「滑卡片区域没反应、只有滑边缘才行」。
- **Cause:** scrollWheel 先派发给指针命中的最深视图(SwiftUI hosting 内部的滚动区域),未被显式放行时不保证沿响应链回到自建容器;非激活面板也不成为 key,无法用键盘/焦点事件兜底。
- **Prevention:** 用 `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` 在 `NotchPanel` 里拦事件(`event.window === self` 且面板可见才处理),不消费原事件,纵向滚动/惯性(`momentumPhase != []`)原样放行;锁轴(累积位移 ≥12pt 且横向占优)后累积 ≥50pt 才切一张,并在手势结束前不再触发,避免一次滑动连翻多张。

## DEV-035: 非激活面板要收键盘只能靠 `nonactivatingPanel` + `canBecomeKey = true`
- **Pitfall:** 照搬灵动岛/Dock 预览的 `NSPanel`(`canBecomeKey = false`)做剪贴板面板:面板能显示、点击行也生效,但搜索框打不进字,↑↓/↵/esc 全无反应——键盘事件仍派给原前台 app。
- **Cause:** `.nonactivatingPanel` 只表示「点击本窗口不激活 app」,并不让它成为 key window;`canBecomeKey = false` 时本 app 又没有全局事件 tap 转发按键(灵动岛/Dock 预览靠 listen-only CGEventTap 拿输入,剪贴板面板不装 tap),于是永远收不到键盘。
- **Prevention:** 想「不激活 app 也能打字」,`styleMask` 用 `.borderless + .nonactivatingPanel`、`canBecomeKey = true`、`becomesKeyOnlyIfNeeded = false`,`makeKeyAndOrderFront` 后断言 `isKeyWindow == true`(本项目其余面板故意保持 false,别顺手改);兜底分支一旦 `NSApp.activate`,真的会抢走前台,必须记住 `previousApp` 并在收起/粘贴前 `NSRunningApplication.activate` 还原,否则合成 ⌘V 会打到自己身上;方向键/回车/esc 用 `NSEvent.addLocalMonitorForEvents(.keyDown)` 按 `event.window === panel` 拦截并吞掉,其余按键放行给 SwiftUI `TextField`(输入法搜索依赖它)。

## DEV-036: 面板贴插入点弹出：AX 坐标是「主屏左上为原点」，且必须在面板成为 key 之前取
> **已废弃**：剪贴板面板已改为鼠标定位，不再取插入点；本条仅作历史记录。
- **Pitfall:** 用 `kAXFocusedUIElementAttribute` + `AXBoundsForRange` 拿 caret 矩形后直接当 Cocoa 坐标用,面板出现在屏幕另一半;或热键里先 `makeKeyAndOrderFront` 再取焦点,拿到的永远是面板自己的搜索框,锚点跑到面板上。
- **Cause:** AX 的全屏坐标原点在主屏**左上角**(y 向下),Cocoa 原点在主屏**左下角**;非激活面板一旦成为 key window,系统焦点即转移,`AXFocusedUIElement` 变成我们的 `TextField`。
- **Prevention:** 坐标换算 `cocoaY = NSScreen.screens[0].frame.maxY - axRect.maxY`,并用 `NSScreen.screens` 的 `frame.intersects` 判断落屏;取 caret 的时机固定在 `makeKeyAndOrderFront` **之前**,并用 `AXUIElementGetPid != 自己` 兜底跳过自身;`AXUIElementSetMessagingTimeout(0.25)` 防目标 app 卡死拖住热键;密码框(`AXSecureTextField`)直接放弃定位;拿不到 caret 时按「元素 frame → 鼠标位置」降级。

## DEV-037: 液态玻璃作为窗口背景要放在 hosting 之下当兄弟视图，圆角各自设
- **Pitfall:** 把 `NSGlassEffectView` 当 SwiftUI `.background` 或反过来把 hosting 塞进 `glass.contentView`,要么玻璃不出现(被宿主裁剪/不参与窗口背后采样),要么窗口宽高被 SwiftUI 固定 frame 钳死(DEV-024)。
- **Cause:** 液态玻璃是窗口级合成效果,必须整块铺满窗口底层;`contentView` 承载 SwiftUI 会经约束链反向钳制窗口尺寸。
- **Prevention:** `contentView` 用普通 `NSView` 容器:先 `addSubview(glass)`(frame=bounds、autoresizingMask=[w,h]、`cornerRadius` 自己设),再 `addSubview(hosting)` 盖在上面(同样只用 autoresizing);不要给容器加 `masksToBounds`(会把玻璃/磨砂裁掉),圆角分别设在玻璃(`cornerRadius`)或磨砂(`layer.cornerRadius + masksToBounds`)上;外观、降低透明度、Liquid Glass 强度全交给系统原生玻璃,**不要**再叠 `tintColor`/不透明底/描边(会和系统效果打架、也看不出滑杆效果),也不要用 `alphaValue` 调玻璃透明度(会连内容一起透明)。


## DEV-038: 自动隐藏 Dock 时 AX 报的是「隐藏位」坐标，Dock 预览的触发区/闸门会整体偏出屏幕
- **Pitfall:** 开启 Dock 自动隐藏后，Dock 预览「偶尔能弹」:鼠标停在图标上大概率不弹,只有贴到屏幕最底一条缝才弹。日志里的 Dock 项缓存 bbox 是 `(410, 961, 588, 54)`,而屏幕只有 `1470×956` —— 整条落在屏幕底边之外。
- **Cause:** Dock 自动隐藏时其 AX item/窗口的 position 是隐藏位(比展开位低一整条 Dock 高 ≈ 54pt),缓存重建若在隐藏期间发生就一直是这个坐标;触发区(`stripTriggerMargin=30`)与闸门(`stripGateMargin=16`)都以外扩后的条带判定,于是触发线从 `y≥872` 偏移到 `y≥931`、闸门从 `y≥886` 偏移到 `y≥945`,只剩屏幕最底 11pt 能过。再叠加「指针停住后不再有 mouseMoved + 展开动画期间 AX 命中返回桌面」,失败一次就再无重试机会。
- **Prevention:** 条带几何一律先吸附到最近的屏幕边(横向排布贴底边、纵向排布贴左/右边,已落位时幂等)再外扩,不要直接相信 AX 的 position;闸门优先用「权威命中到的图标自身 frame」(实时)而非 Dock 整体条带;权威命中失败且指针仍在 Dock 区域、Dock 未落位(主窗口框 <95% 在屏内)时按 ~120ms/1.2s 短期重试,成功命中后把图标 frame 与缓存比对,不一致就置缓存失效重建。

## DEV-039: 灵动岛形状不等于窗口 frame，遮罩路径必须由「形状状态」驱动
- **Pitfall:** 想做「水滴/沙漏」形状（顶栏宽 ≠ 细颈宽 ≠ 底部鼓包宽）时，仍按 `layout()` 里的 `bounds` 生成遮罩路径：弹簧每帧改的是窗口 frame，遮罩只会画成「等比放大的刘海形」，细颈永远出不来；反过来若把形状宽当成窗口宽去 `setFrame`，窗口宽度会在细颈、鼓包之间来回跳（窗口只是形状的包围盒，包围盒宽度 = 三条里最大的那条）。
- **Cause:** 旧实现的隐含前提是「形状 == 窗口矩形」，所以 `layout()` 直接拿 bounds 重建路径；引入细颈后窗口宽（`max(顶栏, 细颈, 鼓包)`）与形状侧墙位置不再一致。
- **Prevention:** 动画驱动的是 `NotchShapeState`（锚点 centerX/topY + 顶栏宽/细颈宽/鼓包宽/高），六分量弹簧每帧算完先 `apply(state)`：窗口 frame 取包围盒、再把三条宽度经 `applyProfile` 喂给遮罩容器；`layout()` 只重建路径、不自行推导宽度（否则会覆盖参数）。路径里的三次贝塞尔拐点全部要能在「三宽相等」时退化为直线，否则终形态和原来的刘海形对不上（对着 `notchShapePath` 单测几个关键状态：迷你刘海/三宽相等的终形态/细颈/沙漏，用 `CGPath.contains` 采样打印 ASCII 轮廓最快）。窗口包围盒在非等宽形状下可能比终形态窄，命中区域仍用弹簧终点 `targetFrame`（DEV-029），别用当前 frame。**若真要三宽不等**（水滴/沙漏），收尾过冲别靠欠阻尼：`dampingFraction < 1` 的过冲量是「各自行程」的百分比，细颈行程最长会冲出到比顶栏还宽，视觉上腰先鼓一下，得改用显式过冲目标态 + 临界阻尼。当前版本三宽恒相等（单段弹簧，见 DEV-040），所以尺寸分量直接用阻尼比 < 1 给过冲是安全的。

## DEV-040: 灵动岛弹出动画别做多段编排——单段「宽领先/高滞后」弹簧才像 iOS 的液体铺开
- **Pitfall:** 想做「一滴水滴滴下来」的六段编排（横条→回缩→细股→鼓包→过冲→回落）：看起来有想法，实际观感是「一条黑横杠突然从刘海两侧伸出来 → 缩回去抖一下 → 黑条下面挂一根细黑柱 → 才终于填满」，累计 1.1–1.4s，明显顿挫拖沓；内容只在最后一段才淡入，前面一大段时间是个空黑壳。
- **Cause:** ① 每段都独立临界阻尼、交接阈值又取 0.85–0.92，等于每段「几乎跑完、速度掉到很低」才重新起跳，加速度不连续 → 六次轻微减速—再启动，读作顿挫；② 段1/段2 在宽度已到 80%/72% 终宽时高度还停在刘海高（≈26pt），面板被拉成远扁于终形态的横条（282×26），超出刘海硬件的部分立刻可见；③ 段3 把窗口压到 52pt 宽，SwiftUI 内容（按终尺寸固定 frame）只剩中间一条被遮罩裁出的窄缝，虽然 alpha 为 0，但整段没有任何视觉承载。
- **Prevention:** 展开用**单段弹簧**，靠「宽度领先、高度滞后」拉开层次：宽 response 0.32 / ζ 0.70、高 response 0.36 / ζ 0.78、锚点（centerX/topY）临界阻尼（DEV-027），三宽同参 → 形状全程是等比放大的刘海形，尺寸分量各只过冲一次（宽 ≈+3%、高 ≈+1% 行程）。实测 382×309 面板：可见位移 ~0.35s 完成（宽峰值 203ms、高峰值 287ms），子像素尾巴 0.6s 内收干净。内容透明度由引导分量（宽度）的位移进度驱动、进度 60% 即完全不透明（≈0.1s），起手就能看到内容随形状长出来；透明度只作用在 hosting 上，黑底形状始终不透明（DEV-022）。验证节奏别靠肉眼：`ZEROFLOW_NOTCH_TRACE=1` 逐帧打印 `t/dt/topW/h/alpha`，方向反转应该只有 1 次（过冲那一下）、`dt` 无尖峰（有尖峰 = 主线程卡顿，多半是 refit/内容测量）；快速反复看动画用 `ZEROFLOW_NOTCH_SHOW=1`（启动即弹，指针移出不会自动收起）。

## DEV-041: 灵动岛触发方式分叉别只在事件入口判模式，在途的延迟收起回调同样要判
- **Pitfall:** 加「单击触发」选项后只在 `mouseMoved` 入口 `guard mode == .hover` 挡住悬停逻辑，仍会出现「切到单击模式后，面板被上一次悬停模式留下的延迟收起定时器关掉」——用户什么都没点，面板自己消失。
- **Cause:** 收起不是即时的：`scheduleHideAfterDelay` 把「延时后仍 visible」的判定放在异步闭包里，闭包触发时模式可能已经切换；入口处已返回的旧回调不受影响。同理 `suppressReshow`（收起后指针仍在热区则不重弹）在单击模式下也无人清理，切回悬停模式后指针停在刘海上会一直不弹。
- **Prevention:** 模式判定下沉到决策点：异步收起闭包内再校验 `triggerMode == .hover`；`hidePanel` 只在悬停模式下置 `suppressReshow = true`（单击模式无悬停重弹问题，也不该留下永不清除的抑制位）。设置值直接读内存中的 `SettingsStore.shared`，不额外加通知，改设置后下一次交互即按新规则，已弹出的面板不受影响。

## DEV-042: 卡片切换滑动过渡要由面板弹簧时钟逐帧驱动，别赌 SwiftUI 首帧/隐式动画
- **Pitfall:** 想在 `NSHostingView` 里做「旧卡滑出 / 新卡滑入」：一次把 `rootView` 换成终态、同一轮主线程把进度 0→1 再重建内容视图、或只在 `onAppear` 里 `withAnimation` 起跳，结果都只是一次瞬间替换，看不到过渡；`.animation(_:value:)` 也不动。另一个隐蔽问题：`.clipped()` 裁在整块面板宽上时，行程 `卡片宽 + 24` 不足以让旧卡完全滑出（面板宽 ≈ 卡片 + 2×(16+侧墙内缩)），终点会在留白里留一条旧卡边。
- **Cause:** ① 0 与 1 落在同一次 SwiftUI 更新事务里会被合并成终态，「跳变」从未发生；② `onAppear` 不保证首帧 0 已经上屏（`NSHostingView` 挂载与首次提交常合并）；③ `hosting.rootView` 整体换值会换身份，隐式动画不跨身份插值；④ 旧卡若按新布局重排（列宽/内容高跟着变），滑动过程中还会变形。
- **Prevention:** 进度不要交给 SwiftUI 自己起跳：面板持有 `CardSlideDriver`（`ObservableObject` + `@Published progress`），由 `NotchSpringAnimator` 的同一个 120Hz 时钟积分一路 slide 弹簧（response 0.32 / ζ1.0，临界阻尼零过冲），切卡时 `applyLayoutFrame`（形状弹簧）与 `animateSlide` 同轮启动；`allSettled` 必须同时看形状和 slide，否则形状无位移/先落定时 `stopTimer` 会把 slide 一起停掉。SwiftUI 侧只让两个 `SlideCard` 包装视图 `@ObservedObject` 观察进度（整个 `NotchContentView` 不要观察，避免日历/资源卡按 120Hz 重算），offset 公式：旧卡 `-step*travel*progress`、新卡 `step*travel*(1-progress)`。`CardSlide` 在切换时冻结 `travel = max(两卡宽)+24` 与 `viewportWidth = max(两卡宽)`；`contentSlot` 用 `.frame(width: viewportWidth, height: cardSlotHeight).clipped()` 再 `.frame(maxWidth: .infinity)`，裁在卡片区边界、顶部条/箭头不动。旧卡用「切换前几何」原样渲染（card/contentHeight/scale，列宽由卡宽反推）。方向语义：step = -1（上一张 / 左箭头 / 左滑）旧卡向右出、新卡自左入；+1 反向。双指方向要先把 delta 归一到同一基准：系统按自然滚动设置翻转 `scrollingDeltaX`，`isDirectionInvertedFromDevice == true` 时取原值、false 时取反；本机实测（自然滚动开，inverted=true）双指左滑累积为**正**、右滑为负，所以归一后 **> 0 才是左滑** → step -1（与左箭头完全一致），< 0 → +1。别按「左滑 = 负 delta」的直觉写映射——macOS 上报的符号与直觉相反；实机日志 `Notch swipe: raw dx=... inverted=... acc=... step=...` 是唯一可靠依据。断点：`present` 里 `slideDriver.progress = 1` + `cancelSlide()`；滑动落定后 `finishSlide()` 只走 `updateContentView` 清掉旧卡；`isSliding` 期间控制器忽略新的切换请求（连点不把当前卡瞬移回中心）。
- **Note（本机验证手段）:** 这个环境里 `AXIsProcessTrusted()` 为 false，脚本点不了箭头；`screencapture` 与 `CGWindowListCreateImage` 都只返回空白/白图（缺屏幕录制权限），逐帧抓屏对比也不可行。要肉眼验证就用 `ZEROFLOW_NOTCH_SHOW=1` 起一个临时实例手动点箭头/双指滑动，别把「定时器自动切卡」这类测试钩子留在代码里。

## DEV-043: 面板 contentView 从裸 hosting 换成容器后，`contentView?.fittingSize` 会失效
- **Pitfall:** 给面板加玻璃背景（`glass + hosting` 兄弟结构）时把 `contentView` 从 `NSHostingView` 换成普通容器，随后 `centerOnMouseScreen` / `layoutAndPosition` 里用 `contentView?.fittingSize` 量内容尺寸会拿到 0/旧值——容器一般只装子视图、没有 Auto Layout 依赖，fittingSize 不等于 SwiftUI 的自然尺寸。
- **Cause:** `fittingSize` 走的是约束/内在内容尺寸链，裸 `NSHostingView` 有 SwiftUI 内容的内在尺寸，容器没有。
- **Prevention:** 液态玻璃面板统一用一个 `PanelHostingContainer`（玻璃垫底 + hosting autoresizing 跟随，DEV-037），并暴露 `contentFittingSize = hosting.fittingSize`；面板定位/定窗改量这个值，别再依赖 `contentView?.fittingSize`。玻璃层位置要么 autoresizing、要么在容器 `layout()` 里按 bounds 重设（内缩量也要在此补齐，否则尺寸变了玻璃边距不跟随）。

## DEV-044: 新 SDK(27.x) 下合成鼠标事件的 API 形态变化
- **Pitfall:** 写「检查鼠标是否按住」这类合成事件辅助逻辑时用老的 C 函数 `CGEventSourceButtonState(.combinedSessionState, .left)` 编译报错；顺手补的 `.middle` 也报 `CGMouseButton has no member 'middle'`。（该处代码来自已撤销的 Dock 快捷键弹出功能，API 形态结论仍然有效。）
- **Cause:** 新 SDK 把 CoreGraphics 事件源的全局 C 函数换成了 `CGEventSource` 的实例/类型方法（`CGEventSource.buttonState(_:button:)`），且 Swift 侧 `CGMouseButton` 只暴露 `.left`/`.right`（`kCGMouseButtonMiddle` 其实存在但没桥接成 case，中键由右键 tap 监听覆盖即可）。
- **Prevention:** 新 SDK 写合成事件相关代码时，事件源状态查询一律用 `CGEventSource(button/key)State(_ stateID:)` 系实例 API；遇到 `has been replaced by` 的报错直接改用提示的新形式，别套老 C 函数名。另：8 个 `(1 << CGEventType.xxx.rawValue)` 的 OR 长链别再包一层 `CGEventMask(...)` 括号函数调用，拆成 `let mask: CGEventMask = ... | ...` 逐行写，否则「compiler unable to type-check in reasonable time」。

## DEV-045: 自动隐藏的 Dock 无法用「临时弹出」做快捷键预览（AXManualHide 在 macOS 26/27 已不存在）
- **Pitfall:** 想做「按修饰键热键让自动隐藏的 Dock 短暂弹出看清图标」：合成 `mouseMoved` 把指针瞬移到屏幕边缘再移回，功能能看到弹出，但指针被瞬移会打断用户手上的指向/悬停（编辑器画线、拖拽、悬停卡片都跳），体验不可接受；改用未文档化 AX 属性 `AXManualHide` 的方案，在本机 macOS 26/27 上完全读不到该属性，功能无法实现，最终整体移除（不要再重新尝试这条路）。
- **Cause:** ① Dock 的自动隐藏弹出只认物理指针贴边，基于指针的触发必然要动真实光标；② `AXManualHide` 只存在于旧版本 macOS 的 Dock AX 树，本机实测 Dock 进程 AX 子树共 17 个元素（AXApplication / AXList / AXDockItem×15），`AXUIElementCopyAttributeNames` 的属性列表里没有任何 `AXManualHide`，即使先 `AXUIElementSetAttributeValue(dockApp, "AXEnhancedUserInterface", kCFBooleanTrue)` 成功（err=0）也不会出现。
- **Prevention:** 排查 Dock 的 AX 结构时注意 **`kAXWindowsAttribute` 在 Dock 上返回空数组**，Dock 的图标元素挂在 `kAXChildrenAttribute` 子树里（`DockHoverPreviewController` 的建缓存逻辑即按此枚举，DEV 见其 1121 行附近注释）；要按 role 递归枚举，别指望 `kAXWindowsAttribute`。想验证某个未文档化属性是否存在，用 `AXUIElementCopyAttributeNames` dump 整棵子树的 role + 属性名，再决定方案；若目标属性不存在，直接放弃功能，不要回退到移动指针的方案。

## DEV-046: 翻转鼠标滚轮只能走事件层,且必须区分鼠标/触控板与合成事件
- **Pitfall:** 改系统「自然滚动」偏好(`com.apple.swipescrolldirection`)会把触控板一起反转;在 CGEventTap 里不区分来源,两指滚动也会被翻转;不排除 `eventSourceUnixProcessID != 0` 的事件,会和其他滚动工具(或驱动软件)叠加成双重反转。把 `DeltaAxis` 取反后立即读回 `PointDelta` 会发现系统已按倍数重算;若先写 Point/FixedPt 再写 DeltaAxis,取反结果被覆盖,方向偶发不生效。
- **Cause:** 触控板与妙控鼠标的 scrollWheel 恒为 `scrollWheelEventIsContinuous == 1`,传统滚轮鼠标为 0;手势/惯性阶段的事件同样进 tap。`CGEventSetIntegerValueField(kCGScrollWheelEventDeltaAxis1)` 会让 macOS 内部重算 `FixedPtDelta`(1x)与 `PointDelta`(实测合成 line 事件是 10x),覆盖顺序决定最终增量。
- **Prevention:** 只对 `continuous == 0 && scrollPhase == 0 && momentumPhase == 0 && pid == 0` 的事件取反,垂直/水平分别处理 axis1/axis2;写字段顺序固定为 `DeltaAxis → FixedPtDelta → PointDelta`(后写保住高精度滚轮的加速度),实测取反后三个字段同号且量级不变。tap 需辅助功能权限:沿用 `DockClickMinimizer` 的独立线程 runloop + 2s 重试建 tap(授权后无需重启),布局校验用 `ZEROFLOW_SCROLL_DEBUG=1` 打印 `continuous/phase/momentum/pid/增量`,触控板事件应全部是 continuous=1。

## DEV-047: 剪贴板图片不要用 `NSImage(contentsOf:)` 全量解码做缩略图/预览
- **Pitfall:** 列表行只要 22pt 图,却对历史图片整张 `NSImage(contentsOf:)` 解码并放进无上限 `NSCache`;一张 2940×1912 的剪贴板 PNG 就多出 20+MB `Image IO` 脏页,面板关闭后仍常驻(实测 60MB,其中 Image IO 27MB)。`ClipboardMonitor` 只是读像素尺寸也用 `NSBitmapImageRep(data:)`,同样触发整张解码。
- **Cause:** `NSImage` 是惰性容器,一旦被 SwiftUI 渲染就按原尺寸建立位图;`Image(nsImage:).resizable()` 不会阻止这次全尺寸解码。尺寸信息在文件头里,不需要像素数据。
- **Prevention:** 用 ImageIO 按用途出图:`CGImageSourceCreateWithURL` + `CGImageSourceCreateThumbnailAtIndex`(列表 `maxPixelSize` 64、预览 1024,`CreateThumbnailFromImageAlways`),代价按 `宽×高×4` 记入带 `totalCostLimit` 的 `NSCache`;读尺寸用 `CGImageSourceCopyPropertiesAtIndex` 的 `kCGImagePropertyPixelWidth/Height`,不要构造 `NSBitmapImageRep`。缩略图上限取 `min(maxPixelSize, 原图长边)`,避免小图被放大。

## DEV-048: tap 安装成功后必须 invalidate 2s 重试定时器
- **Pitfall:** 五个 CGEventTap 服务都在 tap 线程 runloop 上常驻一个 2s 重复 `CFRunLoopTimer` 兜底重试;tap 一次装成功后定时器仍在每 2s 唤醒一次 runloop(回调里发现 `eventTap != nil` 直接返回),造成无意义空闲唤醒。
- **Cause:** `runTapLoop` 先 `installTap` 再 `installRetryTimer`,`CFRunLoopTimerCreate` 的重复间隔不会因 tap 已存在而自动停。
- **Prevention:** 用属性保存 `retryTimer`;`installTap` 成功后(与置 `eventTap` 同一把锁内)取出并清空,再 `CFRunLoopTimerInvalidate`;`installRetryTimer` 在 `eventTap != nil` 或定时器已存在时直接返回,创建后若 `isRunning` 已为 false 也要 invalidate;`stop()` 里连同 tap 一起 invalidate。这样只有「创建失败」期间才保留 2s 重试。

## DEV-049: 导出 PNG 走 `tiffRepresentation` + `NSBitmapImageRep` 会叠三份全尺寸位图
- **Pitfall:** `NSImage.pngData` 用 `tiffRepresentation` → `NSBitmapImageRep(data:)` → `representation(using: .png)` 编码时,源位图之外又临时生成 TIFF 数据和第二份解码位图;5K 截图(5120×2880 RGBA,单份≈56MB)实测编码峰值多出约 230MB,而实际 PNG 只有 0.3MB。`encodeExportInBackground` 里再 `NSBitmapImageRep(data:)` 仅为打日志,又多一份全图解码。
- **Cause:** AppKit 的 TIFF 中转是「先序列化再解码」的旧路径,`representation(using:)` 内部还会复制;这些临时对象都按整图尺寸分配。
- **Prevention:** 直接 `cgImage(forProposedRect:)` 取底图,用 `CGImageDestinationCreateWithData` + `CGImageDestinationAddImage` + `CGImageDestinationFinalize` 编码(实测同一 5K 图峰值 230MB→68MB);日志尺寸从 `NSImage.size`(导出图按像素 1:1 建)取,别再为日志解码整张 PNG。

## DEV-050: 数据监控的 `@ObservedObject` 要下移到对应卡片,别挂在整个面板内容视图
- **Pitfall:** `NotchContentView` 顶层 `@ObservedObject` 同时观察系统资源/正在播放,2s 采样一更新就重算整个内容视图,连带日历月网格与全部布局;实际只有一个模块在显示。
- **Cause:** SwiftUI 的依赖跟踪以「声明了 `@ObservedObject` 的 View」为单位,顶层对象变化会让整个 `body` 失效,与当前显示哪个模块无关。
- **Prevention:** 顶层只放真正跨模块的依赖(日历 model);给资源/音乐各包一个 `@ObservedObject` 的宿主 View(`ResourceCardHost` / `MusicCardHost`),把该模块的列内容放在宿主闭包里。采样更新只重算宿主子树,日历月网格不参与。

## DEV-051: 历史异步加载后,已弹出的面板还持有加载前的快照
- **Pitfall:** 剪贴板历史改后台加载后,`ClipboardPanelController.show()` 里的 `ClipboardViewModel(items: store.items)` 是在加载完成前取的快照(首次打开实测 `items=0`,列表空白且不会再变),因为面板不会自动重读 store。
- **Cause:** view model 的 `items` 是值拷贝,`ClipboardHistoryStore.items` 后续的 `@Published` 更新不会传到模型。
- **Prevention:** 面板 `observe(model)` 时同时订阅 `ClipboardHistoryStore.shared.$items`(`.dropFirst()`),把新数组写回 `model.items`、夹紧 `selectedIndex`、清掉已失效的 `previewItem`;首次从空变非空时再 `applyFrame` 重算面板尺寸。异步 loader 侧则需要在完成前缓冲 `insert`,并让 `clear()` 递增 generation 作废在途加载。

## DEV-052: 事件监听器 token 不能存进 SwiftUI `@State`——会与 StoredLocation 组成自持环
- **Pitfall:** 编辑页把 `NSEvent.addLocalMonitorForEvents` 返回的 token 存在 `@State private var keyboardMonitor: Any?`,`onDisappear` 里也 `NSEvent.removeMonitor` 并置 nil,但每开关一次编辑页仍常驻约 120MB(5K 底图)。实测 200 次循环 footprint 单调上涨,`EditDocument deinit` 一次都不打;`leaks` 报 `Swift._ContiguousArrayStorage<Optional<Any>>` → `_NSLocalEventObserver` → `__NSMallocBlock__` → `Closure context` → `SwiftUI.StoredLocation<Optional<Any>>` 又指回数组的 ROOT CYCLE,`EditDocument`/`NSImage` 挂在 closure context 下。
- **Cause:** monitor 的 block 捕获了整个 `EditorView` 值(含 `@StateObject doc` → 底图),而 SwiftUI 把 `@State` 的存储放在 `StoredLocation.savedValues` 里;token 与 observer/block 互相引用后,即便视图已消失、`removeMonitor` 已调用,`StoredLocation` 仍被环自持,没有外部入口能把整串打断。
- **Prevention:** 监听器 token 的持有者放到 SwiftUI 状态之外:用单例 `EditorKeyMonitor.shared` 存 `monitor`,视图 `onAppear` 调 `install(handler:)`(内部先移除旧的)、`onDisappear` 调 `removeAll()`;窗口关闭路径(`CaptureCoordinator.windowWillClose`)再兜一次 `removeAll()`。修后同一压测 10 次循环 footprint 12.6→31.9MB 后完全走平,每轮 `EditDocument deinit` 均触发。同理检查其他 `@State eventMonitor`(如 `ShortcutRecorderView`);调试用 `ZEROFLOW_MEM_DEBUG=1`(30s footprint tick)与 `ZEROFLOW_MEM_CYCLE=<notch|clipboard|switcher|editor>:<count>[:openMs[:closeMs]]`(`ZEROFLOW_MEM_CYCLE_EXIT=1` 跑完退出),看 `MEM cycle`/`MEM deinit` 日志判断是「首用缓存一次性抬升」还是「每轮都漏」。

## DEV-053: 导出画布必须把上下文翻成「左上原点 y 向下」,否则标注相对底图上下镜像
- **Pitfall:** 编辑页里画的框/线/气泡/马赛克,保存或复制出来的 PNG 里位置不对——整体像是「错位」:在图片中间偏上加的框,导出后跑到中间偏下(实测 2560×1440 截图,画布拖拽得到图像坐标 y=333.8..473.5,导出后落在 y=242..390.5,即关于水平中线的镜像)。底图本身是正的,只有标注层被翻。
- **Cause:** 元素一律存「图像坐标:原点左上、y 向下」(与 SwiftUI 画布一致),但 `exportedImage` 用的是 `NSGraphicsContext(bitmapImageRep:)`,位图上下文原生是「左下原点、y 向上」且 `isFlipped == false`;`NSBezierPath(rect:)`/`move(to:)` 直接吃图像坐标就被按 y 向上解释,整层上下镜像。只居中对称的元素(正好在垂直正中、横跨全高的框)看不出问题,所以很容易误判成「位置漂移」。
- **Prevention:** 导出时把 CTM 整体翻成 y 向下,并给上下文打上 flipped 标记:`let cg = bitmap.cgContext; let ctx = NSGraphicsContext(cgContext: cg, flipped: true)`,`cg.scaleBy(pixelScale)` 后再 `cg.translateBy(x: 0, y: image.size.height)` + `cg.scaleBy(x: 1, y: -1)`。翻转后 `NSBezierPath` 的几何坐标可直接用图像坐标,`NSAttributedString.draw(in:)` 仍正向且顶部对齐;但**图片必须显式 `respectFlipped: true`**(`image.draw(in:from:operation:fraction:respectFlipped:hints:)`),否则底图和马赛克叠加图会被画反——`drawMosaicIntoCanvas` 里的 `overlay.draw(...)` 同样要加。收尾用 `cg.flush()`(`flushGraphics()` 走的是原 rep 上下文)。核对方式:造一张「顶部一条红带」的底图 + 左上角一个框,导出后从最终 PNG 解码回来按行打印 ASCII 色块,别只盯着预览。

## DEV-054: `CGImageSourceCreateThumbnailAtIndex` 出大尺寸会永久留下脏页,不能当「预览图按需重算」用
- **Pitfall:** 为了「关掉剪贴板面板就把内存还回去」,把预览缓存改成每次打开面板都重新从原图解码,结果内存反而越用越高:开关面板 + 展开预览 20 次,footprint 从 31MB 一路涨到 79MB,每轮稳定 +2.9MB,malloc 却几乎不动(说明不是我们的堆对象)。同一张 2940×1912 的 PNG 连解 30 次 +93MB,无上限、不回收。
- **Cause:** `CGImageSourceCreateThumbnailAtIndex(..., kCGImageSourceThumbnailMaxPixelSize: 1024)` 每次调用都会在进程里留下约「输出尺寸」量级的脏页(CG/ImageIO 侧的 VM),即使 CGImage 引用早已释放、`autoreleasepool` 也已清空。实测隔离进程 30 轮:`thumbnail→1024` +93MB、`thumbnail→512` +5.6MB/8 轮、`thumbnail→96` +6MB(每轮 0.2MB)。**同一张图重复解码不会复用,是按调用次数累加的。**
- **Prevention:** ① 显示路径不要碰原图:`clipboard-images/derived/<id>.thumb.jpg`(≤96px)与 `<id>.preview.jpg`(≤1024px)落盘,列表/预览只读这两种小文件(读 1024px JPEG 30 次只 +0.1MB);② 需要从大图生成派生图时,用 `CGImageSourceCreateImageAtIndex` 全解码 + `CGContext.draw` 按长边缩放重绘(30 次仅 +3.3MB,比 thumbnail API 省 28 倍),再 `CGImageDestination` 写 JPEG;③ JPEG 无 alpha,重绘前先铺白底,否则透明 PNG 变黑块;④ 内存缓存只为「面板打开期间」服务(缩略图 3MB、预览 `countLimit = 1`),`dismiss()` 里 `purgeMemoryCaches()` 整体清空。
- **验证:** `ZEROFLOW_MEM_CYCLE=clipboard:20`(压测里每次都会展开预览)应稳定在 ~26MB 且每轮零增长;改前同条件是 46MB 并持续上涨。

## DEV-055: `ScrollView` + `VStack` 会把所有行一次性建出来,缩略图跟着全量解码
- **Pitfall:** 剪贴板面板最多只显示 10 行,但历史里每条图片记录都在开面板瞬间被解码一次(每行 `thumbnail(for:)` 都在 `body` 里同步调用),历史里图片一多就是成百次解码,首帧明显卡顿,内存也被顶上去。
- **Cause:** `ScrollView { VStack { ForEach ... } }` 不是懒加载容器,`VStack` 的子视图会全部实例化并参与布局,`body` 里的解码调用自然全跑一遍。
- **Prevention:** 列表容器一律用 `LazyVStack`;行内的图片读取要保证是「小文件快路径」(见 DEV-054),否则懒加载也挡不住滚动时的同步解码。

## DEV-056: 剪贴板面板弹出后默认选中的首条不会展开预览
- **Pitfall:** 热键弹出面板后默认高亮第一条,但鼠标不动、也不按 ↑↓ 时,等再久右侧预览都不会出来;必须先按一下 ↓ 或悬停到别的行才「突然好了」。日志里只有 `clipboard panel shown` 与首帧 `preview=false`,没有任何后续 `preview=true` 帧。
- **Cause:** 预览的停留计时(`schedulePreview()`)只由 `hover(_:)`(且 `index != selectedIndex`)和 `moveSelection(by:)` 触发,`show()` 从不为自己选中的首条起计时;另有两个反向因素:① 视图挂载时 `TextField` 会把空查询原样回写一次,`$query` 的 sink 误判成「用户搜索」,`handleQueryChange()` 直接把刚起的计时取消;② 历史是后台加载的(DEV-051),冷启动弹出时 `items` 还是空,`selectedItem == nil` 也起不了计时。
- **Prevention:** 三处补齐——`show()` 在 `makeKeyAndOrderFront` 之后调一次 `schedulePreview()`;`ClipboardHistoryStore.$items` 的 sink 在 `previewItem == nil` 时补一次(应对异步加载);`$query` 的 sink 先与上次生效值比对,值没变就忽略(滤掉挂载时的空回写),真正改词才取消计时并收起预览。`hover` 命中已选中行时也要能起计时(否则悬停首行同样没反应),但已有 `pendingPreview` 就不要重置倒计时。核对方式:`ZEROFLOW_CLIPBOARD_DEBUG=1` 启动,日志应出现 `frame ... preview=true`,且**没有** `hover row` / 键盘事件。

## DEV-057: agent 会话里 `xcodebuild` 报 `SwiftUIMacros ... produced malformed response`
- **Pitfall:** 在受限沙箱(自动化/agent 进程)里构建时,凡是带 `@State`/`@Published` 的文件全部编译失败:`external macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; .../swift-plugin-server produced malformed response`,同时 stderr 有一行 `sandbox-exec: sandbox_apply: Operation not permitted`。看起来像工程/SDK 问题,实际与代码无关(新建最小 `@State` 用例同样失败)。
- **Cause:** 宏展开由独立进程 `swift-plugin-server` 完成,它启动时会给自己套一层 seatbelt 沙箱;宿主进程已在沙箱内时该 `sandbox_apply` 被拒,插件服务握手失败,前端只能报「宏类型找不到」。
- **Prevention:** 构建时临时关掉编译器的子进程沙箱即可:`xcodebuild ... OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" build`(命令行传入,别写进 pbxproj)。`swiftc -Xfrontend -disable-sandbox -typecheck` 可先做最小复现验证。

## DEV-058: 多显示器下 Dock 悬停预览只在一块屏生效——Dock 的 AX 树只暴露一块屏的 Dock
- **Pitfall:** 接了外接屏后,只有一块屏的 Dock 能弹预览,另一块屏怎么悬停都没反应(日志里连 `resolve` 都没有)。看起来像「副屏 Dock 的 AX 命中拿不到」,但真正的原因在触发阶段。
- **Cause:** ① Dock 进程的 `kAXWindows` 恒为 0(实测),`dockBarFrameTL()` 永远是 nil;② Dock 应用元素的 `kAXChildren` 只有 **1 个 `AXList`**,里面是**一块屏**的图标(实测 14 项坐标全在主屏,指针移到另一块屏后这棵树不变——跟着主屏走,不跟指针走);`CGWindowList` 里 Dock 也只有 1 个窗口。③ 于是 `dockRegionTL()` 退化成「缓存项 bbox ± margin」,只覆盖那一块屏;另一块屏悬停时快路径不命中、又不在条带内 → `scheduleShow` 从不调度,流程在触发阶段就断了。④ 兜底 `isNearDockEdgeFallback` 只在条带为 nil 时可用,缓存有效时永远不可达,所以没有兜底。
- **Prevention:** 触发/闸门改成**每块屏各一条 Dock 边缘带**(`dockBandZonesTL`):用 `NSScreen.frame − visibleFrame` 量 Dock 所在边与厚度(自动隐藏时为 0,用常量 96/110pt 兜底),横向跨度用缓存条带宽度 ×1.2 居中到各屏(各屏 Dock 内容一致、宽度相同);「在不在图标上」只由 AX 权威命中判定。同时把坐标翻转基准从 `union.maxY` 改成**主屏**(Cocoa 原点所在屏)的 `maxY`,否则外接屏摆到主屏上方时全局 y 会整体偏移一块屏高;`placement` 改按 Dock 朝向判断,不再用缓存 bbox 的横竖。
- **验证:** `defaults write com.zeroflow.app dockPreviewDebug -bool true` 后重启,副屏悬停应出现 `resolve pt=... item=...` 并弹面板;若日志只有 `not dock item, chain=...`,说明该屏 Dock 展开后仍不在 AX 树里(需换数据源),chain 里会直接给出命中的元素角色。

## DEV-059: Dock 贴左/右边时 AX 给的是退化坐标(16×0 挤在 (-10,0)),面板会飞到屏幕角落
- **Pitfall:** 把 Dock 放到屏幕左侧/右侧后,悬停图标弹出的预览面板跑到屏幕左上角(甚至半截在屏外),而且卡片是横排的。看起来像「朝向判断错了」,其实是坐标本身就不可用。
- **Cause:** Dock **自动隐藏 + 贴在侧边**时,`AXApplicationDockItem` 的 `kAXPositionAttribute`/`kAXSizeAttribute` 全是退化值——实测 14 个项一律 `(-10, 0)` + `16×0`(底部 Dock 隐藏时给的是「隐藏位」但尺寸有效,所以只有侧边中招)。于是 ① 缓存 bbox = `(-10,0,16,0)`,`width >= height*2` 恒成立 → 朝向被误判成 `.bottom` → 面板跑到图标**上方**且横排;② 命中项 frame 退化 → 面板锚点落在左上角,定位完全跑偏。
- **Prevention:** ① 朝向改读 Dock 的全局偏好 `CFPreferencesCopyAppValue("orientation", "com.apple.dock")`(left/right/bottom),拿不到再退回 `frame − visibleFrame` 的 inset,最后才看缓存条带;② `isDegenerateDockFrame`(宽或高 < 8)把退化 frame 挡在所有几何计算之外:边缘带跨度退化时铺满整条边、`syncDockCache` 不拿它判「坐标过期」、`isDockSettled` 视为未落位(保留展开动画的重试预算);③ 锚点走 `sanitizedAnchor`:退化时按「指针 + 该屏 Dock 边缘带」重建(侧边:带宽 × 42 高、以指针 y 居中;底部:42 宽 × 带宽、贴底边),面板就能正常贴在图标旁边。
- **验证:** 临时切 Dock 朝向(`defaults write com.apple.dock orientation -string left|right|bottom; killall Dock`)后看调试日志:`show ... placement=rightOf anchor=(0,699,110,42) panelTL=(112,547,...)` 表示左侧 Dock 面板落在图标右侧且竖向排列;`placement=leftOf` 对右侧 Dock 反之;底部仍是 `placement=above`。
- **附带坑:** 净化锚点要在 `present` **取锁之前**算——`sanitizedAnchor → dockBandZonesTL → dockStripTL` 会再 `lock.lock()`,`NSLock` 不可重入,持锁调用会把主线程直接锁死(表现为面板永不出现、应用像卡住)。

## DEV-060: Dock 预览「鼠标还没走到面板上就消失」——`insetBy` 符号写反，保活区其实是内缩的
- **Pitfall:** 预览面板弹出后想把鼠标移到面板上点卡片，结果一动就消失，慢一点根本够不到；越快越容易成功。看起来像「收起延迟太短」，调大也治不彻底。
- **Cause:** 保活判定写的是 `anchorFrame.insetBy(dx: keepAliveInset, dy: keepAliveInset)`——`insetBy` 的**正值是内缩**（外扩要传负值，同文件里 `resolvedItemGateSlack` 就是 `-slack`）。于是保活区比图标/面板各自**小** 6pt，而面板底边离图标顶边只有 2pt：图标上沿到面板下沿之间凭空多出一条 `6 + 2 + 6 = 14pt` 的死带。指针慢速穿过这条死带就会超过 200ms 宽限，面板当场收起。
- **Prevention:** ① 外扩一律写 `insetBy(dx: -keepAliveInset, ...)`（`NotchHotspotController` 同款写法可对照）；② 除两个矩形各自外扩外，再用「图标 → 面板」走廊（`isInTransitCorridor`：沿朝向轴从图标边缘延伸到面板边缘、横截面取图标跨度）兜住两者之间的缝——**不要**改判 `anchor ∪ panel` 的包围矩形，它在底部 Dock 下会横向吞掉整条 Dock 邻域（含所有隔壁图标），导致「移到无窗口图标上旧预览不收」，见 DEV-065；③ `.visible` 时若指针命中「另一个图标」，先用「图标 → 面板」走廊（`isInTransitCorridor`：沿朝向轴从图标边缘延伸到面板边缘、横截面取图标跨度）挡一道——放大 Dock 下缓存几何会整体漂移，上行途中很容易误命中隔壁图标，一旦按「换目标」处理就会 `softHidePanel` 掉刚弹出的面板；④ 弹出/收起两个延时都做成设置页滑杆（`dockPreviewHoverDelayMs` / `dockPreviewHideDelayMs`，后者默认 500ms），每次调度时现读，改滑杆即时生效。
- **验证:** `defaults write com.zeroflow.app dockPreviewDebug -bool true` 后慢速把指针从图标移到面板：日志不应出现 `hide (left icon+panel region)`；滑杆把「收起延迟」拉到 2000ms 后，离开图标再移回面板应能救回同一个面板。

## DEV-061: 鼠标去面板途中蹭到隔壁图标 → 当前面板立刻被收掉（「换目标先 softHide」的代价）
- **Pitfall:** 面板弹出后往面板上移，途中手一抖压到隔壁图标，当前面板当场消失，得重新悬停。越靠边的图标越容易中招（面板居中后两侧都是别的图标）。
- **Cause:** `.visible` 里「命中另一个图标」的分支原本会 `softHidePanel()`（视觉上立刻 `orderOut`，状态留在 visible 等新目标重弹）。它存在的原因是**换目标时要避免旧内容残留**：新目标还要走 `hoverDelay` 才解析出窗口，这段空窗里若继续显示旧 app 的卡片，用户会以为点的是新 app 的窗口。但「蹭一下就走」和「真的停在隔壁」在缓存几何上看不出区别，于是路过也按换目标处理 → 面板秒收；而 300ms 后新目标在指针已经移到面板/空中时解析必然失败，`failResolve` 又把面板硬收一次，用户根本来不及。
- **Prevention:** ① 换目标**不再**预先 softHide（函数已删）：旧面板留着，新目标到期由 `present` 复用同一面板原位换内容，解析失败见下条；② `failResolve` 增加「保面板」分支——面板开着且指针仍在 `isInKeepAliveRegion`（图标∪面板外扩 + 并集走廊）里时，只作废这次 show（`pendingShowGen = nil; showGen += 1; hideGen += 1`），面板与状态原样保留，去留交给保活/收起延迟；指针真的离开了才 `hidePanel`；③ `present` 成功后 `hideGen += 1`，作废「按旧锚点算出来」的宽限隐藏——否则指针停在隔壁图标不动时没有 move 事件来 bump，新面板会在 500ms 后被那条旧定时器收掉。
- **验证:** 悬停图标 A 出面板 → 指针斜着蹭过隔壁图标 B 再移到面板上：面板应保持（日志出现 `keep panel, resolve miss (...)` 而不是 `hide (...)`）；停在 B 上不动 ≥300ms 才应该换成 B 的内容。

## DEV-062: 副屏预览能弹出、但「移到隔壁图标」不换内容——换目标判定只走了缓存快路径
- **Pitfall:** 主屏一切正常；副屏悬停图标能弹出缩略图，但指针移到旁边的图标上，面板内容不切换（主屏同操作会换）。看起来像「换目标逻辑坏了」，其实主屏根本没走到那段代码。
- **Cause:** `.visible` 里「换到隔壁图标」靠 `cachedItem(at:)` 命中不同 id 来判定。而 Dock 的 AX 树只暴露**一块屏**的图标（DEV-058），副屏 Dock 的图标坐标压根不在 `dockItems` 里 → `hit` 恒为 nil → 换目标分支永远不进；于是指针离开当前图标后只剩「保活失败 → 宽限隐藏」一条路，表现为面板要么不换、要么过一会儿自己收掉。触发/解析本身没问题：`resolveTarget` 走的是 `AXUIElementCopyElementAtPosition` 系统级命中测试，对任意屏都有效。
- **Prevention:** `.visible` 里补一条「缓存没覆盖」的换目标通道——指针不在保活区、但仍在 Dock 边缘带（`isNearDockStrip`，带是每屏各一条）里时，按 `hoverDelay` 重新走一次 AX 权威命中：命中同一图标内容不变，命中隔壁则 `present` 原位换内容。同时因为 `scheduleShow` 会置 `pendingShowGen`，宽限隐藏不会在这段窗口里把面板收掉。
- **验证:** `defaults write com.zeroflow.app dockPreviewDebug -bool true` 后在副屏从一个图标平移到隔壁，日志应出现第二条 `resolve pt=... item=...` 且 `show ... placement=... anchor=...` 的 anchor 变成新图标；主屏行为不变（走缓存快路径，没有额外 resolve）。

## DEV-063: 副屏「换隔壁图标」彻底修好——把缓存布局跨屏投影，别指望 AX 覆盖所有屏
- **Pitfall:** DEV-062 给副屏补了「按延时重走 AX 权威命中」的换目标通道，但实测仍不换内容。日志里能看到副屏 Dock 的图标坐标根本不在缓存里（`strip` 落在另一块屏），`hit` 恒为 nil；而 AX 命中在副屏上也不一定给出图标项（Dock 的 AX 树只暴露一块屏，见 DEV-058）。
- **Cause:** 换目标、右键抑制、`hoverItemID` 全部建立在 `cachedItem(at:)` 上，而这个缓存只有一块屏的坐标；副屏唯一能用的 AX 权威命中又不可靠。等于副屏没有任何「这是哪个图标」的信息来源。
- **Prevention:** 在 `cachedItem(at:)` 里做**跨屏投影**——各屏 Dock 内容/尺寸完全一致、底部 Dock 各自居中、侧边 Dock 各自贴边，所以把整条缓存布局按「屏幕中心/屏幕边」平移到指针所在屏即可命中：底部 `dx = to.midX − from.midX, dy = to.maxY − strip.maxY`（`strip.maxY` 取缓存条带下沿，缓存处于自动隐藏的「隐藏位」时同样成立），侧边同理按 `minX/maxX` 对齐。投影后 `cachedItem` 一并返回**投影后的 frame**，`resolveAndShow` 的兜底与锚点都用它，面板才贴在副屏图标上。同时把 `ResolveOutcome` 拆出 `menuElement`，让 `notDockElement` 也能走缓存兜底（右键菜单仍不兜底）。
- **附带坑:** `cachedItem` 持锁期间**不能**调 `dockEdge()`——它的兜底分支会调 `dockStripTL()` 再取锁，`NSLock` 不可重入会死锁；改用纯读的 `Self.dockOrientationRaw()`（只读 `com.apple.dock orientation`）。

## DEV-064: 换图标偶发失败的真凶——放大动画期间 AX 命中抖动，一次失败就判「不在图标上」
- **Pitfall:** 副屏（或任何屏）沿 Dock 平移换图标时**时好时坏**：同一手势有时能换、有时面板直接收起；换个速度又好了。日志里同一个坐标相隔 170ms 两次解析结果完全不同。
- **Cause:** ① Dock 开了放大（magnification）时图标在平移，`AXUIElementCopyElementAtPosition` 在动画中途有时只返回通用的 `AXDockItem` 角色（不是 `AXApplicationDockItem`），`isDockItemElement` 判 false → `resolveTarget` 返回 `notDockElement`；② `scheduleResolveRetry` 当时要求「Dock 尚未落位」才重试，而放大动画期间条带是**已落位**的 → 不重试 → `failResolve` 直接 `hidePanel`；③ 缓存快路径同时因为条带是动画中途快照（实测 bbox 在 588/626/661/689 之间反复变化）而漏命中。三者叠加 = 「一次抖动就收面板」。
- **Prevention:** ① `scheduleResolveRetry` 的门槛从「`isNearDockStrip && !isDockSettled`」放宽为「`isNearDockStrip`」——指针还在 Dock 边带里就说明这次失败是时序竞态，重试预算（0.12s × 10 ≈ 1.2s）内旧面板保持不动，预算用完才真收；② 权威命中同时接受通用角色 `AXDockItem`（`isAnyDockItemElement`，只用于命中、不参与缓存收集，避免分隔符/堆栈污染条带 bbox）；③ 解析日志加 `settled=` 便于区分「隐藏位」与「放大动画」两类竞态。
- **排查提示:** `DockHoverPreview: started (rev=...)` 会打印代码版本标记——怀疑「改了代码但跑的还是旧二进制」时先看这条；另外 `open` 一个已在运行的 app 只会激活旧进程，**必须**先 `pkill -f "Zeroflow.app/Contents/MacOS/Zeroflow"` 再 `open`。

## DEV-065: Dock 预览「移到没有窗口的图标上，旧预览不消失」——保活区用了 图标∪面板 的包围矩形
- **Pitfall:** 悬停有窗口的图标 A 弹出预览，指针平移到隔壁**没有窗口**的图标 B 上，A 的预览一直挂着不收；若 B 有窗口则能正常原位换内容。看起来像「无窗口目标没触发收起」，实际是保活判定把 B 也圈了进去。
- **Cause:** `isInKeepAliveRegion` 除图标/面板各自外扩，还判了 `anchor.union(panel)` 的包围矩形（DEV-060 ② 的旧做法）。底部 Dock 下该矩形横向从「图标最左」跨到「面板最右」，而面板远宽于图标 → 整条 Dock 邻域（含所有隔壁图标）都落在保活区里。于是指针停在 B 上时两条路都卡住：① `.visible` 的 `keepAlive` 为 true，只 `bumpHideGen()`，连权威命中都不再走；② 若先进了换目标分支（缓存命中 B 且不在走廊），`resolveAndShow` 对 B 得到空窗口列表 → `failResolve` 的「keep panel」分支又因保活区命中而保留旧面板。
- **Prevention:** 保活区改为「图标自身 ∪ 面板自身 ∪ `isInTransitCorridor` 走廊」，**删掉并集分支**：走廊沿朝向轴从图标边缘延伸到面板边缘、横截面只取图标跨度（再外扩 `keepAliveInset`），缝隙照样覆盖，但不会横向吞掉邻域。`failResolve` 复用同一函数，于是「指针停在别的图标上且该目标无窗口」自然落进收起分支——且是立即收，不等收起延迟。
- **代价:** 从图标**斜向**移向面板角落时可能短暂出走廊，触发一次收起延迟（默认 500ms）；指针进面板后 `bumpHideGen` 取消。观感上是一次可配置延迟，不会闪。
- **验证:** 悬停有窗口的 A → 平移到隔壁无窗口的 B：日志应出现 `hide (target has no windows)` 而不是 `keep panel, resolve miss (target has no windows)`；平移到有窗口的 C 仍原位换内容；慢速从 A 移向面板仍不掉（DEV-060 的验证照旧通过）。

## DEV-066: 自动隐藏 Dock 时「Dock 没展开也弹预览」，以及偶发「面板过于偏下」——两条链路都缺「Dock 真的在屏上」这个判据
- **Pitfall:** ① 系统设置 Dock 自动隐藏后，鼠标移到屏幕下方（Dock 还没推出来）仍然弹出预览面板；② 极小概率面板位置偏下（半截压在屏幕底边之外），或「Dock 还没滑完就弹，位置算错」。
- **Cause:** 两条问题同源，代码里没有任何「Dock 当前是否真的展开」的判据，几何全靠「屏幕边缘 + 缓存投影」推：
  ① 触发带厚 `bottomBandMinThickness = 96` + `stripTriggerMargin = 30`，屏幕底部 126pt 都算「靠近 Dock」（真实图标行只有 ~54pt）；`cachedItem` 的跨屏投影（DEV-063）把隐藏位条带按 `to.maxY − strip.maxY` 抬到「展示位」，于是 Dock 明明没展开，缓存也给出一个落在图标行内的假命中。延时到期后 `resolveTarget` 返回 `notDockElement`（正确），`resolveAndShow` 的**缓存兜底**照样接受这个投影 frame；位置闸门 `isInDockZone` 又是按屏幕边推的、与命中项无关 → 放行 → 面板弹出。
  ② 展开动画中途 AX 命中给出的 frame 尺寸正常但位置偏低（隐藏位/插值位），`sanitizedAnchor` 只挡退化 frame（宽高 < 8）→ 原样当锚点；`DockPreviewPanel.layoutAndPosition` 的 `.above` 只钳 x **不钳 y**（`origin.y = anchorCocoa.maxY + 2`），锚点在屏幕外时 `origin.y` 变负 → 面板只剩上半截可见。重试机制（DEV-064 放宽成「只要在带内」）只覆盖「解析失败」，**「解析成功但 Dock 还在滑」这条路径没有任何等待**。
- **Prevention:** ① 新增 `dockRevealState(at:)` 三态判据，上屏前必须不是 `.hidden`：**主判据** `liveDockStripTL()` 读 Dock 应用元素子元素（唯一那个 AXList）的**实时** frame（不能用缓存，缓存会长期停在隐藏位），只比「沿 Dock 边法线的贴合程度」（`gap ≤ revealFlushTolerance = 6`）——**不比面积**，放大动画期间条带会横向撑开约 30%，按面积比会误判成「没展开」导致面板永不弹出；**副判据** `dockEdgeArmed`（指针贴过 Dock 那条边 `revealSliver = 6`，系统只在贴边时推出 Dock）**只放行不否决**，只在主判据判不出来（多显示器副屏 / 侧边 Dock 退化坐标 / AX 读不到）时生效，判不出来仍按旧行为放行——宁可保留偶发误弹，也不让这些配置直接失效。② 锚点体检：命中项/投影 frame 的中心必须在指针所在屏内（外扩 2pt），否则 `failResolve` 走重试预算等展开动画。③ `layoutAndPosition` 四个朝向的 origin 一律钳进 `screen.frame`（内缩 8pt），锚点再错也不会把面板推出屏幕。
- **代价:** 自动隐藏时「贴边 → Dock 展开 → 面板出现」多等约一个展开动画（重试 0.12s/次，预算 1.2s），观感是面板晚 0.1–0.2s 出来，不会闪。
- **验证:** `defaults write com.zeroflow.app dockPreviewDebug -bool true` 后重启（**必须**先 `pkill -f "Zeroflow.app/Contents/MacOS/Zeroflow"` 再 `open`，见 DEV-064）。① 指针移到屏幕底部但**不贴边**（Dock 保持收起）→ 日志应出现 `dock not revealed ... liveStrip=...`，不弹面板；② 贴边展开 Dock 后悬停图标 → 日志 `resolve ... reveal=revealed`，面板贴在图标上方；③ 快速划过 Dock 底部 → 面板不应出现位置偏移；④ 若出现「自动隐藏时预览完全不弹」且日志里 `reveal=hidden` 而 `liveStrip` 的 frame 明明已贴住屏幕底边，说明该屏 Dock 的贴合余量超过 `revealFlushTolerance`（6pt），把它放大到 10–12pt 即可（不要直接删判据）。

## DEV-067: 移到隔壁「无窗口」图标时旧预览迟迟不收——换目标判定用了放大态的过期快照，而不是当前实际几何
- **Pitfall:** 悬停有预览的图标 A → 指针平移到隔壁**没有打开窗口**的图标 B：预期是立刻收掉 A 的预览（B 不弹）。实际指针进到 B 左半块时毫无反应，必须再往右移到 B 中间偏右才收。开启 Dock 放大（magnification）时明显，关掉放大几乎复现不出来。
- **Cause:** 「指针是否还在当前图标上」完全由两份**过期快照**判定，而放大是连续动画，布局每一帧都在变：
  ① `currentItemTL` 是 `present` 那一刻（指针压在 A 上、A 已放大到峰值）冻结的 AX frame，之后不再更新。本机实测 `tilesize=40` / `largesize=71`（放大 1.78×）、基准槽距 42pt（DEV-038 日志 588/14）→ 锚点每侧比槽位宽出 `(71−42)/2 ≈ 14.5pt`，再加 `keepAliveInset = 6` → 边界伸进 B 槽位约 **49%**，正好是「中间偏右」。
  ② `cachedItem` 的 `dockItems` 是异步重建的缓存（0.3s 防抖），放大动画期间就是过期快照（DEV-064 实测条带宽度在 588/626/661/689 间跳），B 的 frame 被推右 → 指针在 B 左半块时缓存命中不到 B → `.visible` 的「换目标」分支不触发，只剩「离开保活区 → 500ms 宽限隐藏」一条路。
  **要点：不是「放大后的尺寸不能用」，而是拿历史快照当当前布局。**面板定位需要冻结锚点（否则图标重排时面板会跟着晃），命中判定需要实时几何——两者共用同一个 rect 是设计缺口。
- **Prevention:** 新增 `probeLiveSwitchIfNeeded`：`.visible` 且指针在 Dock 边带内、**沿 Dock 轴**位移 ≥ `liveProbeAxisDelta = 8pt` 时（节流 `liveProbeInterval = 100ms`）问一次 AX 权威命中「这个点是哪个图标」；命中另一个目标就 `scheduleShow(hoverDelay)` 走正常换目标流程。三条硬约束：① AX 调用**必须**异步跑在 `workQueue`——事件 tap 有响应超时，慢了会被系统直接停掉；② 只认沿 Dock 轴的位移，法线方向（图标→面板）不触发，否则会打掉 DEV-060/061 的保活语义；③ 指针在 `panelFrameTL` 内直接跳过（面板下沿可能压进边缘带）。配套：`failResolve` 增加 `differentTarget` 参数——实时命中已确认指针在**另一个**图标上且该目标无窗口时直接 `hidePanel`，不再问保活区；`currentTargetKey`（present 写入 / hidePanel / failResolve 清空）提供身份比对，`pendingSwitchKey` 防止连续 move 反复重置防抖。
- **代价:** 面板显示且指针移动时最多 10 次/秒 AX 命中（静止悬停零开销）。AX 命中抖动仍由 1.2s 重试预算兜（DEV-064）。
- **验证:** `dockPreviewDebug` 打开后 A → B(无窗口)：日志应出现 `switch by live hit pt=... -> app:...`，随后 `hide (target has no windows)`，面板在指针进入 B 后约 100–400ms 内收起（= 探测节流 + 换目标防抖），不再等走到 B 偏右。回归项：DEV-061 的「去面板途中蹭到隔壁图标」仍应是 `keep panel, resolve miss`；DEV-060 慢速从图标移到面板仍不掉。

## DEV-068: 剪贴板面板展开预览时「整体闪一下」——窗口动画跑在 window server，内容重画在主线程
- **Pitfall:** 剪贴板历史面板里某条记录停留超过 `clipboardPreviewDelayMs`（默认 1s）后，窗口从 360 长到 821 展开预览，整个面板闪一下：列表被横向拉宽再弹回。**文本只有 8 行也会出现**，跟内容体积无关。
- **Cause:** `panel.animator().setFrame(_:display:)` 的动画由 window server 推进，不受主线程影响；而内容重画必须在主线程。SwiftUI 首次布局（哪怕只有 8 行文本）要 30–45ms，这段时间主线程不处理 resize 事件，窗口已经从 360 长到 560，backing store 还是 360 宽 → window server 只能把它横向拉宽去填新宽度 → 整块内容变形一下再弹回。实测时间轴（短文本）：窗口 `+45@560 +60@621 +77@676 ...`，内容 `+45@560 +60@621 +77@676 ...` —— 两者同步，说明 **app 在 +45ms 才第一次处理 resize，此时窗口早已 560**。停顿越长拉伸越久：短文本 45ms（≈3 帧），60KB 文本 425ms（≈25 帧）。换成纯色背景、关掉窗口动画，卡顿依旧（413 vs 416ms），证明与玻璃和动画无关，只与「主线程停顿 + 窗口动画不同步」有关。
- **Prevention:** 四件事必须同时成立，缺一个就还会闪：
  ① **内容与窗口尺寸解耦，而且 layer 必须已经覆盖展开态**：`ClipboardPanelView` 根视图固定展开态宽度 `ClipboardPanelMetrics.expandedWidth`（821），预览列宽度恒定占位（未展开时 `Color.clear`）；**`NSHostingView` 也必须固定 821 宽，只让高度跟随宿主**（`autoresizingMask = [.height]`）。只让 hosting 跟随窗口宽度是**不够**的：收起态窗口 360 宽，layer 的 backing store 也只有 360 宽，右侧 461pt 预览列压根没被光栅化，窗口生长时仍要靠主线程逐帧补画，主线程一停顿就回到拉伸老路——这正是「改完还偶发闪一下」的残留原因。定宽后预览列在动画起手前就已画完（app 内离屏取样：生长前右侧预览区已有 5406 个前景像素）。超宽部分由窗口自身裁掉，宿主 layer 默认不 masksToBounds。只用 autoresizing、不用约束、不挂 `glass.contentView`，不违反 DEV-024。
  ② **渲染先于生长**：设完 `previewItem` 后在下一轮 runloop 里 `layoutSubtreeIfNeeded()` + `displayIfNeeded()`，再启动窗口动画（`expandPreview`）。顺序反了就是窗口先动、内容后画。
  ③ **定宽内容必须用 `overlay(alignment:)` 钉在宿主左上**。`.frame(maxWidth: .infinity, alignment: .topLeading)` 在**子视图比宿主宽**时不会靠左，SwiftUI 会把整块内容**居中**：实测把 821 宽内容放进 360 宽宿主，左右各裁 230pt，列表只剩右半截，必须等窗口长到 821 才恢复正常。正确写法 `Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).overlay(alignment: .topLeading) { 定宽内容 }`（`ZStack(alignment: .topLeading)` 同样会被居中，实测无效）。
  ④ 窗口动画**仍用 `animator()`**（0.16s easeOut）。内容固定宽度 + layer 已预渲染后，动画期间零重排、零补画，不会再被拉伸。**不要改成自己开 60Hz 定时器逐帧 `setFrame`**：实测 10 帧共 18ms、单帧最大 2.6ms，视觉与 `animator()` 无差别，却让展开瞬间多占主线程，已回退。
  ⑤ **两个方向都要像抽屉抽出，靠「把内容钉在不动的那条边」实现**（`pinHosting`）：预览在右 → hosting 钉窗口左边缘（`autoresizingMask = [.height]`，内容局部 0 是列表、右侧 461pt 是预览），窗口向右长；预览在左 → hosting 钉窗口右边缘（`autoresizingMask = [.minXMargin, .height]`，`frame.origin.x = 窗口宽 - 821`，内容局部 461 起是列表、左侧 460pt 是预览），窗口向左长。这样窗口无论朝哪边长，列表在屏幕上都不动，另一边就是把已经画好的预览「抽」出来。
  **不要图省事让左展开直接瞬时到位**（早期就是这么绕的）：视觉上「啪」一下变宽，用户会当成动画丢了。也不用担心窗口原点移动导致内容错位——只要 hosting 钉对了边，AppKit 的 autoresizing 会逐帧把 `origin.x` 顶回去，列表始终贴在窗口那条不动的边上。
  切钉法本身不产生跳变：收起态窗口 360 宽，两种钉法下列表都正好铺满窗口，所以 `previewOnLeft` 在收起时可以保持上次的方向、不必回切一次。
  还有：**圆角裁剪要挪到宿主 layer**（`container.layer.cornerRadius + masksToBounds`），不能留在 821 宽的 SwiftUI 内容上——内容恒定 821 而收起态窗口只有 360，画在内容上的圆角会跑到窗口外面，右边缘变直角。
- **代价:** hosting 定宽 821 让 backing store 变成窗口的 2.3 倍（2x 屏 821×422 约 5.5MB），面板 dismiss 时随内容树一起释放。窗口生长期间 hosting 每帧 `layout()` 仅 0.05–0.10ms（布局缓存命中；实测 60 帧共 1.38ms、单帧最大 0.09ms），首次插入约 3ms。
- **验证:** `ZEROFLOW_CLIPBOARD_DEBUG=1` 启动，日志应只有一条 `frame -> ... preview=true ... animated=true`（幂等守卫挡住两条入口重复起手），并跟一条 `preview prerender ...`；收起态应看到完整列表（搜索栏 + 全部行 + 底栏）而不是半截。抽屉方向可在动画中途抓帧核对（`ZEROFLOW_PANEL_SNAPSHOT` 把延时调到 80ms）：右展开中途应是「列表完整在左 + 预览从右边露出一截」，左展开中途应是「预览从左边露出一截 + 列表完整在右」，两边都不该出现拉伸或错位。若又闪了，依次查：根视图是否被改回 `.frame(maxWidth: .infinity)`（内容跟着窗口逐帧重排）、hosting 是否又被改成跟随窗口宽度（预览列没被光栅化）、对齐是否用了 `.frame(alignment:)` 而不是 `overlay(alignment:)`（内容被居中裁切）、`pinHosting` 是否还跟着 `previewSide` 切边。

## DEV-069: 系统 Now Playing 对第三方 app 是空的,「正在播放」必须另配 CoreAudio 出声探测

- **Pitfall:** 灵动岛「正在播放」卡片对 QQ音乐、语音备忘录永远显示「没有正在播放的音乐」,而对 Chrome 却常年显示一个早已不存在的会话。用户报「没什么支持的」,看起来像读取 API 失效,实际是数据源根本不存在。
- **Cause:** macOS 的 Now Playing 是**单一共享槽位**,只有 app 主动向 `MPNowPlayingInfoCenter` 上报才有数据。实测 macOS 27.2.1:QQ音乐(`com.tencent.QQMusicMac`)和语音备忘录(`com.apple.VoiceMemos`)播放中,`MRMediaRemoteGetNowPlayingClients` 返回**空数组**、`MRMediaRemoteGetNowPlayingApplicationPID` 返回 0、`MRNowPlayingRequest.localNowPlayingItem` 为 nil;与此同时 `localNowPlayingPlayerPath` 仍指向一个 Chrome 的 **paused 僵尸会话**(空闲后不释放,`localPlaybackState` 恒为 2)。即:读不到不是 API 被封,而是这两个 app 压根不上报;僵尸会话还会让「谁是当前播放器」的判断被带偏。
- **Prevention:** 双源合并,`NowPlayingMonitor.read()`:
  ① **MediaRemote 优先**:拿到 item 且其 bundleID 出现在出声列表里(或出声列表为空,可能是暂停态)→ 用完整信息(标题/歌手/进度,`canControl = true`)。
  ② **CoreAudio 兜底**:`kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningOutput == 1` 枚举正在出声的进程(macOS 14+ 公开 API,实测能准确抓到 QQ音乐与语音备忘录),用 `NSRunningApplication` 取 bundleID/localizedName 做降级展示,`canControl = false`。
  ③ **过滤**:`activationPolicy == .prohibited` 的守护进程(audiomxd/CoreSpeech/assistantd 等在列表里但不算 app)、自身 bundleID 全部剔除;已知音乐类 bundle 排在前面,避免浏览器视频抢位。
  ④ **僵尸会话判定**:media 的 app 不在出声列表而**另有 app 在出声**时,丢弃 media 改用出声方——否则 Chrome 空闲会话会让卡片一直显示 Chrome 的旧内容。
- **代价:** 降级路径拿不到曲名/歌手/进度,暂停时 CoreAudio 输出归零,卡片要等 `staleLimit`(3 次轮询 ≈6s)才清空,无法显示「已暂停」。
- **验证:** `ZEROFLOW_NOTCH_DEBUG=1 ZEROFLOW_NOWPLAYING_DEBUG=1` 启动(后者让轮询脱离面板模块独立运行),播放 QQ音乐应看到 `NowPlaying: audio-only app=com.tencent.QQMusicMac ...`;播放 Music.app 应看到 `NowPlaying: media app=com.apple.Music sounding=true`。

## DEV-070: MRMediaRemoteSendCommand 的 C 签名是 2 个参数,写错会在 macOS 27 上崩溃

- **Pitfall:** 灵动岛「正在播放」的上一首/播放/下一首按钮按下去 app 直接崩溃:`NSInvalidArgumentException: -[NSObject mutableCopyWithZone:]: unrecognized selector sent to instance`。
- **Cause:** 原实现把符号声明成 `@convention(c) (UInt, AnyObject, DispatchQueue, AnyObject?) -> Void`(4 参数),实际签名是 `void MRMediaRemoteSendCommand(MRMediaRemoteCommand cmd, CFDictionaryRef options)`(2 参数)。多余参数在 arm64 上被忽略,于是 `options` 位置收到的是 `MRNowPlayingRequest` **类对象**;框架内部 `MRMediaRemoteResolveCommandOptions` 会对它调 `mutableCopyWithZone:`,直接抛异常。
- **Prevention:** 按真实签名声明 `@convention(c) (UInt32, CFDictionary?) -> Void`,调用传 `fn(UInt32(command.rawValue), nil)`(实测不再崩溃)。另外**不要用 `controlsAvailable` 决定按钮是否可点**——符号存在不代表目标 app 收得到命令:只有上报 Now Playing 的 app 才是 command handler,CoreAudio 兜底出来的 QQ音乐/语音备忘录必须靠 `NowPlayingInfo.control` 置灰。

## DEV-071: 不上报 Now Playing 的 app 只能用系统媒体键控制,而且必须是 now playing owner

- **Pitfall:** QQ音乐不上报 Now Playing,`MRMediaRemoteSendCommand` 对它无效。逐条试下来:媒体键 `NX_KEYTYPE_PLAY` 第一次也无效,但换了个时机再试却成功了——说明不是通道不通,是**命令被别的 app 吃掉了**。
- **Cause:** macOS 的媒体键不走 CGEventTap,而是走 MediaRemote 的 command 分发,只发给**当前 now playing owner**。实测当时 `localNowPlayingPlayerPath` 指向一个 Chrome 的空闲会话(Chrome 早就不播了但不释放),所有媒体键都被 Chrome 收走;后来通过一次激活把 owner 切到 QQ音乐后,三个键立刻全部生效(PLAY 暂停→播放、NEXT 切歌、PREVIOUS 切回,曲名用 AX 读出来逐次核对过)。另外这些 app 的播放控制栏在 AX 里是自绘 `AXUnknown`(`AXPress` 返回 `actionUnsupported -25206`),菜单栏「播放控制」菜单虽然有 `AXPress`,但**后台 app 的菜单栏项不响应**(`activate` 之后才行),所以坐标点击是唯一能"点"到它的方式——代价是必须抢前台,体验不可接受。
- **Prevention:** 控制通道做成三态 `ControlChannel`:
  ① `.mediaRemote` —— 上报了 Now Playing,发 `MRMediaRemoteSendCommand`;
  ② `.mediaKey` —— 不上报,但 `localNowPlayingPlayerPath` 的 bundleID 与目标 app 一致,发 `NX_KEYTYPE_PLAY/NEXT/PREVIOUS`(16/17/18,`NSEvent.otherEvent(.systemDefined, subtype: 8, data1: key<<16 | 0xa<<8)`,down/up 各发一次);
  ③ `.none` —— 既不上报也不是 owner,**必须置灰**:此时发媒体键会打到别的 app 身上,是最坏的结果。
  曲名同理别依赖窗口标题(窗口一关就没),读 AX 播放控制栏的 `AXDescription`:`歌曲名：虚拟 - 歌手名：陈粒`,按 ` - 歌手名：` 切分即可;`AXUIElementSetMessagingTimeout(app, 1.0)` 防止 app 无响应时把轮询队列卡 6s。
- **未解:** 媒体键是 toggle 语义且全局,Zeroflow 无法指定目标;owner 一旦被别人抢走,按钮就会置灰。语音备忘录等原生 app 的 AX 结构尚未验证(可能有真正的 `AXPress` 按钮,能走更稳的通道)。

## DEV-072: 暂停即「消失」——CoreAudio 出声探测对暂停态是瞎的

- **Pitfall:** 从卡片上点暂停,卡片立刻变成「没有正在播放的音乐」——三个按钮跟着一起没了,用户再也点不回去,只能去 app 里手动恢复。
- **Cause:** `kAudioProcessPropertyIsRunningOutput` 在暂停的瞬间就变成 0,`AudioActivityMonitor.activeApps()` 返回空;而 QQ音乐/语音备忘录这类不上报 Now Playing 的 app 在 `MRNowPlayingRequest.localNowPlayingItem` 里本来就是 nil。于是 `read()` 两个源同时为空 → 返回 nil → 轮询的 `staleLimit`(3 次 ≈6s)把 `nowPlaying` 清空。注意**暂停时 `localNowPlayingPlayerPath` 仍然指向该 app**(实测 `owner=com.tencent.QQMusicMac`),这正是键盘上的播放键能把暂停的 app 唤醒的原因,也是唯一还活着的线索。
- **Prevention:** `NowPlayingMonitor` 里维护 `lastAudioApp`(pid/bundleID/name),两条兜底:
  ① 出声列表空了但记忆里的 app 还在跑、且 owner 仍是它 → 输出 `isPlaying = false` 的 `NowPlayingInfo`,control 照旧按 owner 判定(实测暂停后仍是 `.mediaKey`,按钮可点);
  ② 进程刚启动 / 面板没开过、没有记忆时,直接按 `localNowPlayingPlayerPath` 的 bundleID 找运行中的 app 补出「已暂停」——效果与系统控制中心一致。
  反向约束:owner 已换成别的 app 时**不要**硬留(说明别处接管了播放),清掉记忆返回 nil。
- **验证:** 播放 QQ音乐 → 点卡片中间按钮暂停 → 卡片应显示「● 已暂停」+ 曲名仍在 + 频谱压成基线 + 按钮仍可点;再点一次应立刻恢复(`NowPlaying: sent togglePlay via mediaKey` 后紧跟 `audio-only ... owner=true`)。日志里暂停态会打 `NowPlaying: paused app=... control=mediaKey` 或 `paused(owner) app=...`。

## DEV-073: 卡片里的「真实频谱」只能走 ScreenCaptureKit,而且必须自适应归一化

- **Pitfall:** 想给「正在播放」卡片加律动效果,三种看起来都能拿到音频的路,只有一条真的出声:CoreAudio process tap 建得成功、IOProc 也在跑,但读出来全是静音;ScreenCaptureKit 从 CLI 直接跑会报 `-3801 用户拒绝`;而算出来的 FFT 幅值又是绝对量纲,直接线性映射会全满格或全灭。
- **Cause:** ① **process tap**(`CATapDescription(stereoMixdownOfProcesses:)` + `AudioHardwareCreateProcessTap` + 聚合设备)需要单独的音频捕获授权,**不弹窗、静默失败**:`status=0`、`tapID` 有值、IOProc 触发上百次,但 `maxAbs = 0.0`。② **ScreenCaptureKit 的音频轨**复用「屏幕录制」授权,容器 app 已有该授权,所以只有经 LaunchServices 启动(`open -a`)的 app 能跑通,shell 里 exec 二进制会因 TCC 归属不同被拒。③ FFT 幅值随音量/设备差几十 dB,固定阈值必然失真。
- **Prevention:** `AudioSpectrumMonitor` 的做法:
  ① 数据源:`SCContentFilter(display:excludingWindows:)` + `config.capturesAudio = true` + `excludesCurrentProcessAudio = true`(防自激),视频轨压到 16×16@1fps(SCK 不允许只开音频)。
  ② 取样本用 `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` 拿第一声道,再按 `mNumberChannels` 跳采——**不要**假设 planar 或 interleaved,直接 `CMBlockBufferGetDataPointer` 在非连续块上会失败。
  ③ FFT:1024 点 + Hann 窗 + `vDSP_fft_zrip` + `vDSP_zvabs`,按 `pow(half, b/16)` 对数分桶取均值。
  ④ 归一化:**滚动峰值当参考顶**(立刻跟随更高峰、每帧最多回落 0.4dB),显示范围 `参考顶 - 42dB`,再叠 **9dB 高频补偿**(音乐能量集中在低频,不补偿右半边永远平着);数字静音(`topDb <= -100`)直接衰减到 0,否则参考顶会一路掉、把底噪抬成满格。
  ⑤ 包络:上升直接跟随、下落 `0.75/0.25` 混合;发布限 30fps(`CFAbsoluteTimeGetCurrent` 卡时间戳),FFT 在音频回调队列算完再回主线程赋值。
  ⑥ SwiftUI 侧 30fps 重绘**必须挂在卡片宿主**(`MusicCardHost` 同时观察 `NowPlayingMonitor` 和 `AudioSpectrumMonitor`),挂到顶层会把日历月网格一起重算(同 DEV-050)。
- **代价:** 频谱只在音乐模块显示期间跑(`setActive` 与模块联动),面板收起即停流;首次起流有几百毫秒延迟,刚弹出时是平条。
- **验证:** `defaults write com.zeroflow.app notchAutoShow -bool true` + `notchModule=music` + `notchSnapshot=/tmp/x.png` 后 `open -a`,播放音乐抓图应看到 16 段高低错落的橙色条;暂停后应压成一条基线(不透明度 0.3)。日志出现 `Spectrum: 已启动` 即起流成功,失败会打 `Spectrum: 启动失败 ...`(多半是屏幕录制授权)。

## DEV-074: 触控板「轻点即点击」下 `ButtonStyle.isPressed` 一闪而过,按下动画等于没有

- **Pitfall:** 灵动岛播放控制按钮,用触控板轻点(点按无需按下)能触发动作,但完全看不到按下反馈;只有真的按住鼠标才看得到缩放动画。用户报「功能没问题,就是点了没感觉」。
- **Cause:** 轻点在同一帧里先后投递 mouseDown/mouseUp,`configuration.isPressed` 在 SwiftUI 合并状态更新时直接 true→false,`spring(response: 0.18)` 一帧都没跑就被打断,视觉上等于没变。
- **Prevention:** 按下态要有**最短可见时长**:动作仍交给 `Button`(命中/禁用/`.help` 都不用手写),视觉用 `simultaneousGesture(DragGesture(minimumDistance: 0))` 的 `onChanged` 点亮、`onEnded` 排一个 `asyncAfter(0.12)` 再熄灭。这样无论 down/up 多近,至少渲染出一次按下→回弹。
- **验证:** 轻点(不按下)中间按钮,应看到缩小 + 淡底再弹回;把 `minPressDuration` 调到 0 可复现「点了没反应」。

## DEV-075: 出声探测 ≠ 在播放,而且 helper 进程的 bundleID 与媒体会话对不上

- **Pitfall:** ① 从卡片暂停 QQ音乐后,中间按钮的图标一直是「暂停」(说明它以为还在播),再点也没法回到播放态;② 暂停 QQ音乐后去播浏览器视频,卡片仍然显示 QQ音乐的图标/曲名,但三个按钮实际控的是浏览器。
- **Cause:** ① `kAudioProcessPropertyIsRunningOutput` 在暂停后**不一定归零**(app 仍占着输出流),`read()` 的兜底分支又写死 `isPlaying = true`,于是永远判成播放中,永远走不到「已暂停」兜底(DEV-072 那条只在流真的关掉时生效)。② 音频输出常跑在 helper 进程上(Chrome 的音频服务是 `com.google.Chrome.helper`),媒体会话却记在宿主 bundle(`com.google.Chrome`):`media.appBundleID` 与出声列表精确比对必然失败 → 正在播视频的 Chrome 被判成「僵尸会话」丢掉;退回出声列表后又按 `mediaRank` 把已知音乐 app 排第一,占着流的 QQ音乐继续压过 Chrome。而媒体键按「实际在播的会话」路由,于是出现「卡片显示 QQ音乐、按钮控的是浏览器」。
- **Prevention:**
  ① **播放态直接由「有没有声音」驱动,不要轮询去猜**:`AudioSpectrumMonitor` 暴露 `@Published isAudible`(系统混音超过 `silenceDb + 10` 算有声,带 0.35s 保持防淡出闪断),`NowPlayingMonitor` 在 init 里用 Combine 订阅它——电平一落平就地把 `nowPlaying.isPlaying` 翻成 false,一有声就翻回 true,**不经过 2s 轮询**。`read()` 只用 `audible` 给兜底来源赋初值,`audible == nil`(没在捕获 = 不知道)时才退回 `true`,否则没屏幕录制权限会一律显示「已暂停」。
  ② **别做乐观翻转**:早先版本在 `send(.togglePlay)` 后本地翻状态再挂 4s 窗口,结果和轮询互相打架(用户报「经常出错」)。电平信号本身就是真相且 0.35s 内到位,直接以它为准,少一层猜测就少一类 bug。**并且轮询结果落地时必须按当前电平再校一次**(`publish()` 里做),否则后台队列里读到的旧值会把 `applyAudible` 刚翻好的状态盖回去——症状是「点了播放图标闪一下又变回暂停」。
  ③ **静音时要有人推进状态**:SCK 在完全静音时可能不再投递音频 buffer,`analyze()` 不跑,`isAudible` 就永远停在 true(实测停了 4.5s 才被别的声音事件纠正)。捕获期间挂一个 10Hz 主线程计时器重算 `lastAudibleFrame` 的过期,状态才能自己落回暂停。
  ④ **出声进程不一定能查到 app**:Chrome 的音频 helper 没在 LaunchServices 注册,`NSRunningApplication(processIdentifier:)` 直接返回 **nil**(实测 lsBundle=nil、pathBundle=com.google.Chrome.helper),旧代码 `guard let raw = ... else { continue }` 把整条记录丢掉,症状是「明明有声音,actives 是空的」→ 只能退回 owner 兜底、判成暂停。改成 `proc_pidpath` 从可执行路径取最内层 `.app` 的 bundleID,再交给 `hostApp` 归并到宿主。
  ⑤ **由静变响要立刻补查**:`applyAudible(true)` 顺带 `tick()`(0.5s 限流),否则「切到浏览器视频」要等下一个 2s 轮询才换卡片,用户体感是「切换有点慢」。
  ⑥ **bundle 比对改成家族匹配**:`sameApp(a,b)` = 相等或互为 `.` 前缀(`com.google.Chrome.helper` ↔ `com.google.Chrome`);`AudioActivityMonitor` 把 helper 归并到宿主 app(取最长前缀的 `.regular` 进程),用宿主 pid 读 AX/窗口标题,并按 bundleID 去重。守护进程过滤也从「要求非 `.prohibited`」改成「归并后仍 `.prohibited` 才丢」——helper 的 `activationPolicy` 本身可能就是 `.prohibited`,旧写法会把它们一起过滤掉。
  ⑦ **WebKit 宿主按名字认**:QQ音乐是 WebKit 播放器,音频可能跑在 `com.apple.WebKit.GPU` 上,bundle 前缀归并不出来,只能靠进程名「<宿主> Graphics and Media」前缀匹配宿主 app。
  ⑧ **owner 优先排序**:`activeApps(owner:)` 把 `localNowPlayingPlayerPath` 指向的 app 排最前,`mediaRank` 只当同级 tiebreaker。
  ⑨ **控制按钮别只认 owner**:owner 经常被别的 app 的残留会话占着(浏览器空闲不释放),这时只要目标是**唯一在出声的 app**,媒体键仍会按「有声的会话」路由过去,`control` 用 `isOwner || actives.count == 1` 判 `.mediaKey`,否则 QQ音乐在播也会被置灰成摆设(用户实测反馈)。
  ⑩ **「出声列表空」不等于暂停**:空列表时用 `audible` 区分——有声就按 owner 展示成在播,没声才判暂停(早先版本无条件判暂停,有声时会被轮询反复打回「已暂停」)。
- **代价:** 系统音量调到 0 / 输出静音时会被判成「已暂停」;媒体会话为 nil、owner 是陈旧会话、且出声探测也漏掉进程时,仍分不清谁在响。
- **验证:** `defaults write com.zeroflow.app notchDebug -bool true` 后复现:日志里 `actives=[...]` 应随播放/暂停出现和消失(Chrome 播放时应是 `com.google.Chrome`);点暂停 → `audible=false 当前=.../true` 紧跟一次翻转,图标 0.5s 内变播放;播浏览器视频 → 立刻(不等 2s)出现 `media app=com.google.Chrome sounding=true` 或 `audio-only app=com.google.Chrome`。命令行可复现出声探测:`afplay /System/Library/Sounds/Submarine.aiff` 期间跑 CoreAudio 枚举应看到该 pid 的 `runningOutput=1`。
- **代价:** 系统音量调到 0 / 输出静音时会被判成「已暂停」;媒体会话为 nil 且 owner 是陈旧会话时,仍分不清两个同时「占着流」的 app 谁在响。
- **验证:** `defaults write com.zeroflow.app notchDebug -bool true`(或 `ZEROFLOW_NOTCH_DEBUG=1`)后复现:播放 QQ音乐 → 卡片 `audio-only ... silent=false`;点暂停 → 图标立刻变播放,2s 后日志 `audio-only ... silent=true` 且状态保持「已暂停」;再播浏览器视频 → 日志应为 `media app=com.google.Chrome sounding=true`(或 `audio-only app=com.google.Chrome`),卡片换成浏览器图标与页面标题。

## DEV-076: 两个 app 都暂停时,卡片会跟着「谁抢到媒体会话」乱跳

- **Pitfall:** QQ音乐和浏览器都暂停时,把浏览器切到前台(或它加载了视频但没播),卡片就从 QQ音乐跳到浏览器;反向(切回 QQ音乐窗口)却不跳。用户要的是:只有真的开始播才换卡片。
- **Cause:** `read()` 里有一条 `actives.isEmpty → return media`——没人在出声时直接用系统 Now Playing 的会话。但媒体会话是**单槽**,浏览器一加载视频就把槽抢过去(哪怕没播),于是卡片跟着它跑。而 QQ音乐不上报,永远抢不回这个槽。
- **Prevention:** 在 `read()` 最前面加一条「锁」:没声音(`audible != true`)且出声列表为空时,只要 `lastAudioApp` 还在跑就直接返回它,不看 `media`、不看 owner。真的出声时(`audible == true`)这条自动失效,卡片才换人——正好对上「点了播放才切」。同时暂停态的 `control` 一律给 `.mediaKey`,否则被锁住的那张卡片按钮是灰的,用户点不回去。
- **代价:** 静音播放(系统音量 0、视频本身静音)时卡片不会切过去——没有声音就没有依据。

## DEV-077: 暂停态的图标要跟手,数字静音必须走快速通道

- **Pitfall:** 点暂停后图标要等 0.35s 的静音保持期才翻成「播放」,而按钮的按下动画(0.12s + 弹簧)早跑完了,观感是「动画结束了图标才变」;播放方向却是按下当帧就翻,两个方向不对称。
- **Cause:** `isAudible` 只有「0.35s 没声音」这一个判据,而暂停是**立刻**发生的,0.35s 纯粹是白等。保持期本来是为了挡曲间空隙/淡出。
- **Prevention:** 加第二条判据:连续 3 帧(≈100ms)出现**数字静音**(`topDb <= silenceDb`,只有真正停掉输出才有)就直接判 `audible = false`,不走保持期;保持期只兜「有底噪但很轻」的模糊情况。两条判据合成 `audibleNow`,回调路径和 10Hz 兜底计时器共用。
- **验证:** `afplay /System/Library/Sounds/Submarine.aiff` 结束时日志里的 `audible=false` 应与结束时刻相差 <100ms(实测 0~100ms),图标在按下动画还没结束时就翻过去。

## DEV-078: 多个 app 同时出声时,卡片要显示「最后被操作的那个 app」,而「被操作」有五种形态

- **Pitfall:** 先在浏览器播视频、再打开 QQ音乐播歌,两个音频同时在放。媒体键实际控的是 QQ音乐(最后操作的那个),但卡片显示的却是浏览器的信息——「能控的和显示的」对不上。改成「最近**开始播**的那个」之后,方向反过来坏:浏览器→QQ 修好了,QQ→浏览器又变慢/不切。
- **Cause:** ① 展示顺序按 `mediaRank` + `localNowPlayingPlayerPath` 的 owner 排:Chrome 占着会话槽,永远压过 QQ音乐;`media` 分支又会直接返回上报方,所以 QQ音乐一开局就输。② 元数据轮询 2s 一次,新出现的出声方要等下一个周期才被看见。③ 只用「进了出声列表」判操作是不够的:app 暂停后**未必**离开出声列表(AVAudioPlayer 的 `pause()` 实测 `IsRunningOutput` 仍是 1),而浏览器换一条视频时出声列表、owner、playbackRate **三者全都不变**——这几种「刚被操作」在出声列表上完全看不见。
- **Prevention:**
  ① **展示 = 出声列表里最后被操作的那个**(`pickActive` + `operatedAt` 时间戳取最大)。「被操作」由五个信号合成,缺一个就会有一个方向切不过去:`trackOperations()`
  - 新进出声列表(开始播;暂停后进程消失的 app 走这条,QQ音乐就是);
  - 系统会话 owner 换人(浏览器抢槽/开始播都走这条,不用等出声列表变);
  - 上报会话 `playbackRate` 由停转播(同一个 app 自己暂停再播,owner 不变);
  - 混音由静变响(`applyAudible` 里 `queue.async { sawSilence = true }`,队列侧消费,单候选直接判、多候选退而信 owner);
  - 上报内容换了(曲名变 / 进度跳回 0)——槽和输出流都没动静时只有这里看得出来。
  `media` 只在「它的 app 就是这个人」时才用(信息更全),否则用 CoreAudio 兜底。
  ② **出声列表单独跑高频哨兵**:`activeApps()` 只是几个 CoreAudio 属性读(微秒级),而元数据(AX + CGWindowList)很贵。拆成 0.3s 的 `checkActivity()`,比的是 `bundleID 集合 + SessionSnapshot(owner/playing/title)`,任一变化就 `tick()`,切 app 从「最多 2s」变成「最多 0.3s」。`SessionSnapshot` 的 owner 要**独立于 item 取**:会话可能没有曲名(浏览器加载了页面但没播),那时 owner 照样有值,不能因为读不到 item 就把 owner 一起丢。
  ③ **按钮不再按 owner 置灰**:既然展示的就是最后操作的那个 app,媒体键也路由给它,`control` 直接给 `.mediaKey`;置灰只会让用户点不动自己能控的东西。
- **代价:** 「同时只控一个」做不到——`MRMediaRemoteSendCommandToApp` 这类按 app 发命令的接口需要 `com.apple.mediaremote.send-commands` 私有授权,没有授权时命令会被重定向到当前播放器(实测符号存在但无效),所以没法先把别的 app 暂停再操作目标。另一个代价见 DEV-079(多个 app 同时占着输出流时,声音归属无公开 API)。
- **验证:** 用两个可控假播放器(`/tmp/zfmock`,AVAudioPlayer 循环播 440Hz,**不**上报 Now Playing,行为等同 QQ音乐)跑固定序列,`ZEROFLOW_NOWPLAYING_DEBUG=1` 启动看日志:① 只播 A → `audio-only app=com.example.zfmocka`;② 再播 B → 1.5s 内变 `com.example.zfmockb`(这就是用户要的「显示最后操作的那个」);③ 暂停 B 再播 B → 仍为 B。浏览器侧同理(先播浏览器视频、再播 QQ音乐,日志应出现 `audio-only app=com.tencent.QQMusicMac ... n=2`)。

## DEV-079: 多个 app 同时占着输出流时,「谁在出声」没有公开 API 可归属

- **Pitfall:** 两个 app 都播过、都还占着输出流(暂停但 `IsRunningOutput` 仍为 1),混音从静变响时,代码知道「有人开始播了」,但**不知道是哪个**。这时只能退而信 now playing owner(不上报的 app 又没有 owner),猜错就会出现「卡片显示 A,实际响的是 B」。
- **Cause:** `kAudioProcessPropertyIsRunningOutput` 是布尔值,CoreAudio 的 process object 只暴露 PID / bundleID / IsRunning / IsRunningInput / IsRunningOutput,**没有**每进程电平或时间戳;系统混音(`AudioSpectrumMonitor`)拿到的是所有 app 的叠加,天然无法归属。
- **Prevention:** 目前只在「能归属」的情况下记账(见 DEV-078 的五个信号),归属不了就不改展示,避免瞎猜导致卡片乱跳。真要彻底解决得上 **process tap**(`AudioHardwareCreateProcessTap`,macOS 14.2+)给每个候选进程单独取电平,代价是要为每个进程建 aggregate device + IOProc,属于另一个量级的改动。
- **验证:** 用 `/tmp/zfmock` 的两个假播放器:`play a` → `play b` → `pause a` → `pause b`(此时两个都占着流、混音静)→ `play a`,卡片会停在最后操作的 B 上而不是 A。这是已知限制,不是回归。

## DEV-080: 僵尸 now playing 会话不能当成「刚被操作」,否则浏览器永远压着真正在响的 app

- **Pitfall:** 给 `operatedAt` 加「会话 owner 换人 = 被操作」这个信号之后,浏览器彻底主导:不管最后操作的是谁,卡片都显示浏览器,点播放也确实播浏览器。
- **Cause:** `localNowPlayingPlayerPath` 只表示「谁占着会话槽」,**不代表它在播**。实测 Chrome 空闲后仍长期占着槽,而且槽里连曲名都没有(`owner=com.google.Chrome title=-`)。按「owner 变了就算被操作」记账,等于每次混音从静变响、每次启动首读,都把一次操作白送给这个僵尸;再加上多候选时「退而信 owner」的兜底,它还能在每次静→响时被反复加分。
- **Prevention:** 三条一起改。① owner 换人必须**同时**满足「会话真的在播(`playbackRate != 0`)+ 会话的 bundleID 与 owner 一致 + owner 在出声列表里」才记账,空槽/僵尸一律不认;② 混音由静变响时**只有单一候选**才记账,多候选宁可不动(见 DEV-079),不要退而信 owner;③ 诊断日志打出每个候选「距今多久被记成刚被操作」(`pick=... [bid=2.3s ...]`),下次再出现「为什么显示它」直接看这行。
- **验证:** 浏览器空闲占着槽 + QQ音乐在播时,`NowPlaying: pick=com.tencent.QQMusicMac [com.google.Chrome=从未 ...]`,卡片应显示 QQ音乐。
- **仍存在的限制(见 DEV-081):** 显示对了,但点按钮**不一定控得到它**。

## DEV-081: 媒体键无法定向,卡片显示和按钮实际控制对象可能不是同一个 app

- **Pitfall:** 卡片显示 QQ音乐,点播放却把浏览器里的视频播起来了。
- **Cause:** 播放控制只有一条通道——系统媒体键(`NX_KEYTYPE_PLAY`),它由 MediaRemote 分发给**当前 now playing owner**,调用方无法指定目标。实测排除的替代路径:① `MRMediaRemoteSendCommandToApp(cmd, nil, bundleID, nil)` 传 bundleID 直接 SIGSEGV(第 3 参不是 CFString,真实签名要 playerPath/私有授权);② `MRMediaRemoteSendCommand` 对不上报 Now Playing 的 app 无效;③ QQ音乐的播放控制栏在 AX 里是自绘 `AXUnknown`(`desc="播放"`、有精确 frame、但 `actions=[]`),按不动;④ 就算按 frame 用 `CGEvent.postToPid` 点,QQ 后台时 AX 树连窗口都不暴露(`AXWindows` 为 0,只有它自己在前台才可见),拿不到坐标。⑤ 给 owner 发 `stop` 也踢不掉槽(实测 owner 不变)。
- **Prevention:** 目前**不做特殊处理**,只在 `send()` 里打一行诊断:`send togglePlay card=X owner=Y ⚠️不一致`。**别试图用「显示=按钮能控的那个」来兜**:到底谁会被控,取决于系统按「谁在播/谁最后被操作」做的路由,而我们既拿不到可靠的路由结果(见 DEV-082),合成的媒体键在测试环境里也对不上(打一次 key,Chrome 暂停的视频没恢复、会话方的 mock 也没暂停)——按它做显示规则只会把浏览器重新推上卡片。所以显示仍按「最后被操作的出声 app」,控制照发媒体键。
- **代价:** 只要浏览器(或任何上报 Now Playing 的 app)占着会话槽,媒体键就可能先到它手上;想让 QQ音乐被控,只能等它自己成为路由目标。真正自洽的替代方案只有「显示最后操作的 app + 不可控时置灰」,需要产品上接受按钮点不动。
## DEV-082: 进程内读 MediaRemote 会**冻结**在首次读取,长跑进程永远看不到 owner 变化

- **Pitfall:** app 启动时浏览器正占着会话槽,之后浏览器关了、QQ音乐开始播,卡片却一直按「owner 是浏览器」来判——显示浏览器、控制也发给了浏览器。重启 app 立刻正常。看起来像「显示逻辑又错了」,其实是读数本身是死的。
- **Cause:** `MRNowPlayingRequest` 的类属性(`localNowPlayingPlayerPath` / `localNowPlayingItem`)在**每个进程里只求值一次**就缓存住。实测:让一个上报型 app 成为 owner 再把它杀掉,长跑 20s 的探针在它退出 12s 后仍然报它的 bundleID,而同一时刻新起的进程立刻报 `com.google.Chrome`。注册 `MRMediaRemoteRegisterForNowPlayingNotifications` 也没用。C 接口在这版 macOS 上全被阉:`MRMediaRemoteGetNowPlayingApplicationPID` 恒返回 0、`MRMediaRemoteGetApplicationDisplayID` 恒 nil、`MRMediaRemoteGetLocalNowPlayingPlayerPath` 的 block 根本不回调。
- **Prevention:** 会话改走**子进程**读(`osascript -l JavaScript`,`readNowPlaying()` 优先 `readViaSubprocess()`),进程内只作兜底。实测一次 ~77ms(含进程启动),跑在轮询队列上,2s 一次约 1% CPU,换来的是**每次都是新鲜值**(曲名/歌手/bundleID/playbackRate 全对)。同理,0.3s 哨兵只比出声集合,不再比会话快照(比它没有意义)。
- **验证:** 让上报型 app 成为 owner 再杀掉,新起的进程应报 `com.google.Chrome`;app 不重启也应跟着变(`media(owner)` 日志里的 bundleID 会变)。
