// 手机屏的调度中枢：什么时候加屏、撤屏，窗口怎么放上来、放回去，字号怎么改，手机屏用哪一档；
// App 资源库的动作也在这里：打开 App、新建窗口时等新窗口出来再放，退出 App 前先还原它放上来的窗口。
// 所有动作排成一队依次做（加屏要等上线、搬窗口要核对重试，中间不能被别的动作插进来）。
// 退出 App、关窗口例外：请求发出之后不占着队等结果（Electron 类 App 退出要五六秒，「要存储吗」要等人回答），
// 另起一个盯着，期间别的动作照做；盯到对话框时再排进队把它放上手机屏。
// 屏幕适配（ScreenFit）：手机屏的比例跟着用户的手机走（设置里换了就在线换，不撤屏）；
// 宽度跟着屏上显示的东西走，露着列表是基准宽度，放着窗口是那个窗口要的一档。
// 隔离：只动手机屏和放上来的那一个窗口；加屏、撤屏被系统挪动的其它窗口放回原处、被系统拨动的别的屏设回原来的模式；
// 每一处改动先记账再动手，还原成功才销账。没销的账（Snug 崩溃、App 卡住没放成）
// 在下次启动（recover()）、或下次放窗口之前按账还原，不会被新的记录盖掉。
// 窗口在 Snug 之外没了（手机上关掉、App 自己换了窗口），App 多半已经把手机屏上的大小、字号存下了：
// 账转成留下的账（LeftBehind），它带着手机屏上的大小回来时再还（checkReturns）。
// 手机上点窗口自己的关闭按钮不算在 Snug 之外：先放回原位再关（closePlaced），根本不留账
import CoreGraphics
import Foundation

@MainActor
public final class PhoneDesk {
    public struct State: Equatable, Sendable {
        public enum Screen: Equatable, Sendable {
            case off
            case preparing
            case ready(DisplayID)
            /// 加屏失败（详情在日志里）。按 retryDelays 自动重试，用完就停在这里，直到不要了再要
            case failed
        }

        public var screen = Screen.off
        /// 手机屏上的窗口
        public var placed: Placed?
        /// 手机屏上露着 App 资源库。没放窗口时总是露着
        public var listVisible = true
        /// 正在做的事，做完回到 nil
        public var work: Work?
        /// 要让用户知道的事，下一个动作开始时、或这次远程结束时清掉
        public var notice: Notice?
        /// 已经请它退出、还在等它退完的 App（进程号）
        public var quitting: Set<Int32> = []
        /// 已经请它关掉、还在等它关上的窗口
        public var closing: Set<WindowKey> = []
        /// 在手机上退出了手机屏：这次远程不再加（见 dismissScreen）
        public var dismissed = false
        /// 手机屏上那个窗口的关闭按钮（铺好后读的）。手机上点它不直接关，先放回原位再关（见 closePlaced）。
        /// 在问用户的窗口（挂着「要存储吗」）不给：那时按钮是灰的，点它是想答对话框
        public var closeButton: CloseButton?

        public init() {}

        public var display: DisplayID? {
            if case .ready(let id) = screen { id } else { nil }
        }
    }

    /// 要让用户知道的事，带上是哪个 App 的窗口。措辞归界面层
    public enum Notice: Equatable, Sendable {
        /// 要放的窗口已经关了
        case windowGone(app: String)
        /// 窗口还在，但读不到、挪不动、关不掉（App 没响应，或没有辅助功能权限）；或者请它退出、强制退出的请求没送到
        case windowUnresponsive(app: String)
        /// 还原记录写不进去，不敢动窗口
        case recordUnwritable
        /// 手机屏还没好（屏幕组合还在变）
        case screenNotReady
        /// App 打不开（启动失败）
        case openFailed(app: String)
        /// App 菜单里没有「新建窗口」，或 App 没响应
        case noNewWindow(app: String)
        /// 打开了，但等满了也没有可显示的窗口（收进菜单栏的 App 常这样）
        case noWindow(app: String)
        /// 请它退出了，等满了还没退，也没有对话框：可以强制退出
        case quitStalled(app: String, pid: Int32)
        /// 换成了新手机的比例。UU 只在选屏时按屏幕尺寸开推流，比例变了要在 UU 里切走再切回来，点的位置才对（实测）
        case reshaped
        /// 换了手机型号，但这块屏没能换成新比例（还是原来的）；下次加屏时按新的建
        case reshapeFailed
        /// 放大过字号的窗口在 Snug 之外关掉了，放大的那几级会被 App 记住（VS Code 按工作区记），再打开时可能还大
        case zoomLeftBehind(app: String, steps: Int)
    }

    /// 盯着的 App 退完了、窗口关上了
    public enum Gone: Equatable, Sendable {
        case app(Int32)
        case window(WindowKey)
    }

    public struct Placed: Equatable, Sendable {
        public let window: WindowInfo
        /// 比原来放大了几级
        public var zoom: Int
        public var zoomable: Bool { ZoomBook.isZoomable(window.bundleID) }

        public init(window: WindowInfo, zoom: Int) {
            self.window = window
            self.zoom = zoom
        }
    }

    public enum Work: Equatable, Sendable {
        /// 正在打开这个 App（启动、唤回或新建窗口），等新窗口出来；出来了转成 placing
        case opening(AppInfo)
        /// 正在把这个窗口放上来（换窗口时含放回原来那个），窗口挪好就转成 zooming
        case placing(WindowInfo)
        case puttingBack
        case zooming
        /// 正在把手机屏换成新手机的比例
        case reshaping
        /// 在手机上退出了手机屏，正在放回窗口、撤屏
        case dismissing
    }

    /// 屏幕配置一变，过这么久再检查一次（等系统折腾完）
    static let recheckDelay: TimeInterval = 1.5
    /// 屏幕组合变了（或刚设回别的屏的模式）等这么久，系统挪完窗口再放回
    static let topologySettle: TimeInterval = 1
    /// 窗口挪好、字号改完后等这么久再动下一步：App 要一点时间认到新的大小
    static let settleDelay: TimeInterval = 0.3
    /// 加屏失败后隔多久重试；这几次都不成就不再试，直到不要了再要
    static let retryDelays: [TimeInterval] = [5, 15, 30]
    /// 等新窗口出来时隔多久问一次（实测一次不到 1 毫秒）
    static let windowPoll: TimeInterval = 0.1
    /// 冷启动最多等多久出窗口（实测 ChatGPT 6.6 秒，更重的 App 更慢）；唤回、新建窗口实测都在 0.3 秒内，等 10 秒
    static let launchWait: TimeInterval = 30
    static let windowWait: TimeInterval = 10
    /// 请 App 退出、请窗口关掉之后隔多久看一次结果
    static let watchPoll: TimeInterval = 0.25
    /// 最多等多久才算没动静：退出给强制退出（实测 Electron 类 App 退出要五六秒），关窗口提示无响应
    static let quitWait: TimeInterval = 10
    static let closeWait: TimeInterval = 5
    /// 对话框答完后再等这么久：App 还在、窗口还在，就是点了取消（存储要一点时间，不能一没对话框就下结论）
    static let answerGrace: TimeInterval = 2
    /// 给了强制退出以后再看这么久、隔 stalledPoll 看一次：它自己退了（大型 App 退出要十几秒），提示就撤掉
    static let stalledFollow: TimeInterval = 60
    static let stalledPoll: TimeInterval = 1
    /// 放着的窗口在 Snug 之外没了以后，等它的 App 开出新窗口最多这么久，开出来就接着放上来
    /// （ChatGPT 冷启动约 3 秒后会换掉第一个窗口，实测 11-15）
    static let replaceWait: TimeInterval = 10

    public private(set) var state = State() {
        didSet { if state != oldValue { onChange?(state) } }
    }
    public var onChange: ((State) -> Void)?
    /// 确认 App 退完、窗口关上的那一刻，在撤掉「正在退出 / 正在关闭」之前：数据源据此马上去掉它，
    /// 不然要等下一轮刷新，卡片会以原样闪回一下
    public var onGone: ((Gone) -> Void)?
    /// 即将加屏、撤屏，或把被拨动的别的屏设回去：会话层据此暂缓断开判定（屏幕一变，UU 的信号会抖一下）
    public var onTopologyChange: (() -> Void)?
    /// 设置里的默认字号级数
    public private(set) var defaultZoom: Int
    /// 设置里的手机型号对应的比例：加屏按它建，换比例以它为目标。屏上此刻是哪个比例见 screenFit
    public private(set) var fit: ScreenFit

    private let displays: any PhoneDisplays
    private let windows: any WindowControl
    private let apps: any AppControl
    private let timeline: any Timeline
    private let ledger: RestoreRecord<PhoneRecord>
    private let zoomFile: JSONFile<ZoomBook>
    private var zoomBook: ZoomBook
    private let leftBehindFile: JSONFile<LeftBehindBook>
    private var leftBehind: LeftBehindBook
    private let lane = SerialLane()

    private var wanted = false
    /// 远程在不在进行（会话层的结论，含断开后等重连的那段）：这期间别的屏可能处在远程用的临时模式
    private var remote = false
    private var display: (id: DisplayID, bornAt: TimeInterval)?
    /// 撤掉了、还没真正下线的手机屏：下线那一刻 macOS 才挪窗口、拨别的屏。显示器睡着（Mac 锁屏）时释放的虚拟屏
    /// 要等唤醒才下线（实测，可能是几小时后），等它真下线了再按撤屏前的样子放回（settleDisplays）
    private var retiring: Retiring?
    /// 远程中撤过屏：那时别的屏可能正处在远程用的临时模式，系统套用时连永久配置一起写了。
    /// 远程结束（UU 已经还原）、手机屏不在、屏都醒着时，把别的屏此刻的模式写进永久配置
    private var persistOwed = false
    private var settling = false
    private var placement: Placement? {
        didSet {
            state.placed = placement.map { Placed(window: $0.window, zoom: $0.record.zoom) }
            if placement?.window.key != oldValue?.window.key { state.closeButton = nil }
        }
    }
    private var recheckGeneration = 0
    private var pendingRecheck: Task<Void, Never>?
    private var failures = 0
    private var pendingRetry: Task<Void, Never>?
    private var verifying = false
    private var checkingReturns = false
    /// 刚在 Snug 之外没了的窗口：它的 App 在 replaceWait 内开出不在 known 里的新窗口，就接着放上来
    private var replaced: (pid: Int32, known: Set<WindowKey>, until: TimeInterval)?
    /// 盯着的请求：请它退出的 App、请它关掉的窗口
    private enum Watched: Hashable {
        case quit(Int32)
        case close(WindowKey)
    }
    private var watches: [Watched: Task<Void, Never>] = [:]

    public init(displays: any PhoneDisplays, windows: any WindowControl, apps: any AppControl,
                timeline: any Timeline = SystemTimeline(), paths: SnugPaths, defaultZoom: Int = 2,
                fit: ScreenFit = .standard) {
        self.displays = displays
        self.windows = windows
        self.apps = apps
        self.timeline = timeline
        self.defaultZoom = defaultZoom
        self.fit = fit
        ledger = RestoreRecord(url: paths.phoneRecord)
        zoomFile = JSONFile(url: paths.zoomBook)
        zoomBook = zoomFile.loadOrQuarantine() ?? ZoomBook()
        leftBehindFile = JSONFile(url: paths.leftBehind)
        leftBehind = leftBehindFile.loadOrQuarantine() ?? LeftBehindBook()
    }

    // MARK: 意图

    /// 要不要手机屏（会话、设置、权限合起来的结论）。变了才动
    public func setWanted(_ on: Bool) {
        guard on != wanted else { return }
        wanted = on
        if !on {
            cancelRetry()
            // 退出手机屏只管这一次：不再要了（远程结束、关了开关），下次要时照常加
            state.dismissed = false
        }
        lane.run { await self.reconcile() }
    }

    /// 手机屏上的「退出手机屏」：放回窗口、撤掉手机屏，直到不再要手机屏之前都不再加：这次远程结束、关了开关，
    /// 或者几台同时连着时手机离开超过重连窗口、只剩电脑（手机再回来算下一次，照常加）。
    /// 没接显示器的 Mac 上，手机屏一出现系统就撤掉自己的默认屏，UU远程 里没有别的屏可切，靠它回到原来的画面（issue #8）。
    /// 远程刚结束、屏还没撤完时点的不算：不然会挡掉下一次远程的手机屏
    public func dismissScreen() {
        guard wanted, !state.dismissed else { return }
        state.dismissed = true
        Log.info("手机上退出了手机屏：放回窗口、撤屏，这次远程不再加")
        begin(.dismissing)
        lane.run {
            await self.reconcile()
            self.state.work = nil
        }
    }

    /// 把这个窗口放上手机屏（原来那个先放回原位）。正在退出的 App 的窗口不放：它退完会记住手机屏上那个窄位置
    public func pull(_ window: WindowInfo) {
        guard !state.quitting.contains(window.key.pid) else { return Log.info("\(window.app) 正在退出，不放 \(window.label)") }
        begin(.placing(window))
        lane.run {
            await self.place(window)
            self.state.work = nil
        }
    }

    /// 打开 App，等它的新窗口出来放上手机屏：没在跑就启动，在跑但没窗口就唤回（点在跑且有窗口的 App 是 pull，见 AppList.action）
    public func open(_ app: AppInfo) {
        begin(.opening(app))
        lane.run {
            await self.openWindow(of: app, newWindowIn: nil)
            self.state.work = nil
        }
    }

    /// 给在跑的 App 新建一个窗口（菜单里的 ⌘N），放上手机屏：从出现起就是手机宽度，终端不会因为尺寸剧变重排
    public func newWindow(_ app: RunningApp) {
        guard !state.quitting.contains(app.pid) else { return Log.info("\(app.app.name) 正在退出，不新建窗口") }
        begin(.opening(app.app))
        lane.run {
            await self.openWindow(of: app.app, newWindowIn: app.pid)
            self.state.work = nil
        }
    }

    /// 退出 App（同 ⌘Q）。手机屏上放着它的窗口就先还原（App 退出时会记住窗口位置，不先放回下次就是手机屏那么窄），
    /// 放不回去就不退。请它退出后另起一个盯着：退完了就好；弹出「要存储吗」就把那个窗口放上手机屏，在手机上就能选；
    /// 等满了还没退、也没有对话框，提示可以强制退出
    public func quit(_ app: RunningApp) {
        guard !state.quitting.contains(app.pid) else { return }
        state.notice = nil
        state.quitting.insert(app.pid)
        lane.run {
            if let p = self.placement, p.window.key.pid == app.pid {
                guard await self.returnToOriginal(p) else {
                    Log.warn("\(p.window.label) 放不回去，先不退出 \(app.app.name)")
                    self.state.quitting.remove(app.pid)
                    self.state.notice = .windowUnresponsive(app: p.window.app)
                    return
                }
                await self.matchWidth()
            }
            Log.info("请 \(app.app.name) 退出")
            guard await self.apps.quit(pid: app.pid) else {
                self.state.quitting.remove(app.pid)
                self.state.notice = .windowUnresponsive(app: app.app.name)
                return
            }
            self.watchQuit(app)
        }
    }

    /// 强制退出（提示里的按钮）：未存储的内容会丢
    public func forceQuit(pid: Int32, app: String) {
        state.notice = nil
        unwatch(.quit(pid))
        Log.warn("强制退出 \(app)（pid \(pid)）")
        lane.run {
            if await !self.apps.forceQuit(pid: pid) { self.state.notice = .windowUnresponsive(app: app) }
        }
    }

    /// 关掉一个窗口（同点它的红色关闭按钮）。放在手机屏上的先还原位置和字号（App 会记住关掉的窗口在哪、多大，
    /// 不先放回，下次开出来就是手机屏那么窄），但不恢复全屏：马上就要关了。全屏的先退出全屏，
    /// 不然按关闭按钮没反应（实测 11-14，不论在不在当前桌面空间）。之后另起一个盯着，同退出：
    /// 关掉了就好；问「要存储吗」或「还有进程在跑」就把它放上手机屏；等满了还在、也没在问，提示无响应
    public func close(_ window: WindowInfo) {
        guard watches[.close(window.key)] == nil else { return }
        state.notice = nil
        state.closing.insert(window.key)
        lane.run {
            if let p = self.placement, p.window.key == window.key {
                guard await self.returnToOriginal(p, restoringState: false) else {
                    Log.warn("\(p.window.label) 放不回去，先不关")
                    self.state.closing.remove(window.key)
                    self.state.notice = .windowUnresponsive(app: p.window.app)
                    return
                }
                await self.matchWidth()
            }
            if await self.windows.look(window.key)?.fullScreen == true { await self.windows.setFullScreen(window.key, false) }
            // 飞书、微信点关闭只是把窗口藏起来：在屏上的窗口按完关闭不在屏上了，也算关上
            let wasShown = await self.windows.isShown(window.key)
            guard await self.windows.close(window.key) else {
                let notice = await self.unreachable(window)
                Log.warn("关不了 \(window.label)（\(Self.reason(notice, gone: "已经关了"))）")
                self.state.closing.remove(window.key)
                self.state.notice = notice
                return
            }
            Log.info("关闭 \(window.label)")
            self.watchClose(window, hides: wasShown)
        }
    }

    /// 手机上点了手机屏上那个窗口自己的关闭按钮（手势翻译拦下来的）：和在 App 资源库里关一样，先放回原位、缩回字号再关。
    /// 直接让它关，App 会把手机屏上的大小和字号存下来，下次开出来还是那样（issue #14）
    public func closePlaced(window id: UInt32) {
        guard let p = placement, p.window.key.id == id else { return }
        Log.info("手机上点了 \(p.window.label) 的关闭按钮：先放回原位再关")
        close(p.window)
    }

    /// 关掉提示（「稍后」）。没退出的那个就不再盯了
    public func dismissNotice() {
        if case .quitStalled(_, let pid) = state.notice { unwatch(.quit(pid)) }
        state.notice = nil
    }

    /// 底部小横条：回到 App 资源库（马上露出来），手机屏换回基准宽度。
    /// 提示留着：列表收着时出的错（比如调字号没成），这时才看得到
    public func showList() {
        state.listVisible = true
        lane.run { await self.matchWidth() }
    }

    /// 列表左上角的返回键：回到手机屏上的窗口。换档要一会儿，期间和放窗口一样显示「正在打开」、列表点不了
    public func returnToPlaced() {
        guard let p = placement else { return }
        begin(.placing(p.window))
        lane.run {
            await self.reveal()
            self.state.work = nil
        }
    }

    /// 把手机屏上的窗口放回原位。放不回去（App 卡住）就留在手机屏上，提示一下，可以再点
    public func putBack() {
        guard placement != nil else { return }
        begin(.puttingBack)
        lane.run {
            if let p = self.placement, await !self.returnToOriginal(p) {
                self.state.notice = .windowUnresponsive(app: p.window.app)
            }
            await self.matchWidth()
            self.state.work = nil
        }
    }

    /// 字大 / 字小一级，并记到这个 App 名下。到了上下限什么都不做（界面上那个按钮已经点不了）
    public func zoom(by delta: Int) {
        guard let placed = state.placed, placed.zoomable,
              (placed.zoom + delta).clamped(to: ZoomBook.range) != placed.zoom else { return }
        begin(.zooming)
        lane.run {
            if await self.changeZoom(by: delta), let p = self.placement, let bundle = p.window.bundleID {
                self.zoomBook.remember(p.record.zoom, for: bundle)
                self.saveZoomBook()
            }
            self.state.work = nil
        }
    }

    /// 设置里改了默认级数：以它为准，各 App 记住的级数一起清掉（不然改了看起来不起作用）
    public func setDefaultZoom(_ steps: Int) {
        defaultZoom = steps
        guard !zoomBook.remembered.isEmpty else { return }
        zoomBook.forgetAll()
        saveZoomBook()
    }

    /// 设置里换了手机型号：手机屏在就在线换成新比例，放着的窗口按新比例重新找档、铺满；不在就等下次加屏时按新的建
    public func setFit(_ fit: ScreenFit) {
        guard fit != self.fit else { return }
        self.fit = fit
        guard state.screen != .off else { return }
        // 闲着就马上盖上「正在调整」；别的动作在做时不冲掉它的状态，轮到换比例时再设（同 placeAsking）
        if state.work == nil, display != nil { begin(.reshaping) }
        // 正在加的屏可能是按旧比例建的：一样排进队，轮到时核对
        lane.run {
            if let id = self.display?.id, self.displays.fit(id) != self.fit {
                self.begin(.reshaping)
                await self.reshape(id)
            }
            if self.state.work == .reshaping { self.state.work = nil }
        }
    }

    /// 屏幕配置变了（插拔外接屏、系统改模式、Snug 自己换档、撤掉的屏真下线了）：过一会儿检查手机屏还是不是该用的那一档、
    /// 窗口还铺不铺满；撤屏没办完的接着办
    public func displaysChanged() {
        settleDisplays()
        guard display != nil else { return }
        recheckGeneration += 1
        let generation = recheckGeneration
        pendingRecheck = Task {
            await timeline.sleep(Self.recheckDelay)
            guard generation == recheckGeneration else { return }
            lane.run { await self.recheck() }
        }
    }

    /// 定期调用：手机屏上的窗口被关掉了，就回到 App 资源库。只认窗口服务器的结论：App 一时没响应不算关了。
    /// 窗口还在却不在屏上（被最小化、App 被隐藏、关成了隐藏），手机屏上只剩空桌面：也回到列表，
    /// 但它照旧算放着、还原记录留着，可以返回它、还原或换一个
    public func verifyPlacement() {
        guard placement != nil, state.work == nil, !verifying else { return }
        verifying = true
        lane.run {
            defer { self.verifying = false }
            guard let p = self.placement else { return }
            guard await self.windows.exists(p.window.key) else {
                Log.info("手机屏上的 \(p.window.label) 在 Snug 之外关了，回到 App 资源库")
                self.placement = nil
                self.state.listVisible = true
                self.replaced = (p.window.key.pid, p.known.union([p.window.key]), self.timeline.now + Self.replaceWait)
                await self.leaveBehind(p.record)
                await self.matchWidth()
                return
            }
            if !self.state.listVisible, await !self.windows.isShown(p.window.key) {
                Log.info("手机屏上的 \(p.window.label) 不在屏上了（最小化、隐藏或关成了隐藏），回到 App 资源库")
                self.state.listVisible = true
                await self.matchWidth()
            }
        }
    }

    /// 远程在不在进行（会话层的结论）。远程结束后，远程中撤屏留下的永久配置要重写（settleDisplays）
    public func setRemote(_ on: Bool) {
        guard on != remote else { return }
        remote = on
        if !on { settleDisplays() }
    }

    /// 定期调用、屏幕配置一变也调用：撤屏后手机屏真下线了，就放回窗口、设回别的屏；远程中撤过屏的，
    /// 远程结束、屏都醒着时把别的屏此刻的模式写进永久配置。没事可做时什么都不做
    public func settleDisplays() {
        guard retiring != nil || persistOwed, !settling else { return }
        settling = true
        lane.run {
            defer { self.settling = false }
            if let r = self.retiring {
                guard !self.displays.isOnline(r.id) else { return }
                self.retiring = nil
                Log.info("撤掉的手机屏 #\(r.id) 下线了")
                await self.settle(r.before, after: "撤屏", permanently: r.permanently)
            }
            guard self.persistOwed, !self.remote, self.display == nil else { return }
            let others = self.displays.otherDisplays()
            guard !others.contains(where: \.asleep) else { return }
            self.persistOwed = false
            Log.info("远程中撤过屏，远程结束后把别的屏此刻的模式写进永久配置：\(others.map { "\($0.name) \($0.mode)" }.joined(separator: "、"))")
            for other in others { await self.displays.setMode(other.id, other.mode, permanently: true) }
        }
    }

    /// 有辅助功能权限后调用：上次 Snug 没来得及放回去的窗口，按记录放回去。记录在队里轮到时才读，不会拿旧的放两遍
    public func recover() {
        lane.run { await self.putBackLeftover() }
    }

    /// 定期调用（和 verifyPlacement 同一拍）：刚在 Snug 之外没了的窗口，它的 App 换没换个新窗口（换了就接着放上来）；
    /// 留下的账的窗口回来没有（带着手机屏上的大小回来就还账）。没账可查时什么都不做
    public func checkReturns() {
        guard replaced != nil || !leftBehind.entries.isEmpty, state.work == nil, !checkingReturns else { return }
        checkingReturns = true
        lane.run {
            defer { self.checkingReturns = false }
            await self.followReplacement()
            await self.takeBackReturned()
        }
    }

    /// 退出前：放回窗口、撤掉手机屏，做完才返回
    public func shutdown() async {
        wanted = false
        cancelRetry()
        await lane.run { await self.reconcile() }.value
    }

    /// 等排着的动作都做完，包括还没到点的重试和盯着的退出、关窗（测试用：真实时钟下最长要等 30 秒的重试）
    func idle() async {
        var retry: Task<Void, Never>?
        repeat {
            retry = pendingRetry
            await pendingRecheck?.value
            await retry?.value
            for watch in watches.values { await watch.value }
            await lane.drain()
        } while pendingRetry != retry || !watches.isEmpty
    }

    // MARK: 加屏、撤屏

    private func reconcile() async {
        let on = wanted && !state.dismissed
        if on, display == nil {
            await addScreen()
        } else if !on, state.screen != .off {
            await removeScreen()
        }
    }

    private func addScreen() async {
        state.screen = .preparing
        if let old = retiring {
            retiring = nil
            Log.warn("上一块手机屏 #\(old.id) 还没下线就又要加屏，不再等它：它下线时被挪动的窗口、被拨动的屏不会按撤屏前的样子放回")
        }
        let before = await surroundings(before: "加屏")
        onTopologyChange?()
        do {
            let id = try await displays.create(fit)
            display = (id, timeline.now)
            failures = 0
            // 加屏在远程中：别的屏可能正处在远程用的临时模式，只对本次登录设回
            await settle(before, after: "加屏", permanently: false)
            // 新屏从干净的提示开始：撤屏后才轮到的动作（比如盯着的退出排进队的放对话框）会在没屏时留下提示
            state.notice = nil
            state.screen = .ready(id)
            Log.info("手机屏 #\(id) 已就绪（\(displays.width(id).map { "\($0) 宽" } ?? "不是 2 倍")）")
        } catch {
            state.screen = .failed
            Log.error("加手机屏失败：\(error)")
            scheduleRetry()
        }
    }

    /// 加屏失败后过一会儿再试：手机上没有任何入口能重来，不重试就要等这次远程结束
    private func scheduleRetry() {
        pendingRetry?.cancel()
        pendingRetry = nil
        guard failures < Self.retryDelays.count else {
            Log.error("加手机屏连续失败 \(failures + 1) 次，这次远程不再重试")
            return
        }
        let delay = Self.retryDelays[failures]
        failures += 1
        Log.info("\(Int(delay)) 秒后重试加手机屏（第 \(failures) 次重试）")
        pendingRetry = Task {
            await timeline.sleep(delay)
            guard !Task.isCancelled else { return }
            await lane.run { await self.reconcile() }.value
        }
    }

    private func cancelRetry() {
        pendingRetry?.cancel()
        pendingRetry = nil
        failures = 0
    }

    private func removeScreen() async {
        // 屏要撤了，手机屏上不再算有窗口；放不回去的留着还原记录，下次放窗口或下次启动再放
        if let p = placement { await putBack(p.record) }
        placement = nil
        await retireDisplay()
        state.screen = .off
        state.listVisible = true
        // 这次远程的提示、没盯完的退出和关窗不带到下一次（App 照样在退，只是不再盯）
        state.notice = nil
        watches.values.forEach { $0.cancel() }
        watches = [:]
        state.quitting = []
        state.closing = []
    }

    private func retireDisplay() async {
        guard let (id, bornAt) = display else { return }
        let age = timeline.now - bornAt
        if age < PhoneScreenSpec.minimumLifetime { await timeline.sleep(PhoneScreenSpec.minimumLifetime - age) }
        let gone = displays.bounds(id)
        var before = await surroundings(before: "撤屏")
        onTopologyChange?()
        let offline = await displays.retire(id)
        display = nil
        // 原本就在手机屏上的窗口（手机上新开的）交给系统安置：那块屏已经没了，放回原处只会落到屏幕外
        if let screen = gone { before.windows = before.windows.filter { !screen.contains(CGPoint(x: $0.value.midX, y: $0.value.midY)) } }
        // 远程结束后撤屏（UU 已经还原），撤屏前的样子就是用户自己的设置：系统套用旧模式时也写进了永久配置，
        // 只设回本次登录，磁盘上那组屏幕记的还是旧模式（实测），所以连永久配置一起写回。
        // 远程中撤屏，撤屏前可能是远程用的临时模式：只设回本次登录，远程结束后再写永久配置
        if remote { persistOwed = true }
        let pending = Retiring(id: id, before: before, permanently: !remote)
        if offline {
            await settle(pending.before, after: "撤屏", permanently: pending.permanently)
        } else {
            retiring = pending
            Log.info("手机屏 #\(id) 还没下线（显示器睡着时要等唤醒），下线后再放回窗口、设回别的屏")
        }
        Log.info("已撤掉手机屏 #\(id)")
    }

    /// 手机屏以外的一切：窗口在哪、别的屏是什么模式。macOS 一换屏幕组合就会动它们：把窗口挪来挪去，
    /// 把别的屏拨回它给新的这组屏幕记的模式（远程期间主屏被临时改成 30Hz，撤屏时又被拨回 30Hz，issue #13）。
    /// 加屏、撤屏前记下，换完放回：Snug 的屏来去，别的都照旧
    private struct Surroundings {
        var windows: [WindowKey: CGRect]
        var others: [OtherDisplay]
    }

    private struct Retiring {
        var id: DisplayID
        var before: Surroundings
        var permanently: Bool
    }

    /// 记下来，别的屏的模式也写进日志：出了问题能分清是换屏幕组合时被拨动的，还是之前就是这样
    private func surroundings(before change: String) async -> Surroundings {
        let others = displays.otherDisplays()
        Log.info("\(change)前别的屏：\(others.isEmpty ? "没有" : others.map { "\($0.name) \($0.mode)" }.joined(separator: "、"))")
        return Surroundings(windows: await windows.snapshot(), others: others)
    }

    /// 屏幕组合换完（新屏上线、旧屏下线）后放回：先设回被拨动的屏（模式连分辨率一起变时会再挪窗口），
    /// 等系统挪完，再放回被挪动的窗口。这期间拔掉、新接上的屏不碰
    private func settle(_ before: Surroundings, after change: String, permanently: Bool) async {
        await timeline.sleep(Self.topologySettle)
        let now = Dictionary(displays.otherDisplays().map { ($0.id, $0.mode) }, uniquingKeysWith: { first, _ in first })
        let drifted = before.others.compactMap { was in now[was.id].flatMap { $0.isSame(as: was.mode) ? nil : (was, $0) } }
        if !drifted.isEmpty {
            let detail = drifted.map { was, now in "\(was.name) \(was.mode) → \(now)" }.joined(separator: "、")
            Log.info("\(change)时 macOS 把别的屏拨成了它给这组屏幕记的模式（\(detail)），设回\(change)前的样子")
            onTopologyChange?()
            for (was, _) in drifted { await displays.setMode(was.id, was.mode, permanently: permanently) }
            await timeline.sleep(Self.topologySettle)
        }
        await windows.restore(before.windows, except: placement?.window.key)
    }

    /// 把手机屏换成 fit 的比例（排在队里时又换了几次的，按最新的换）。
    /// 换不成屏还是原来的档位，之后照旧按屏上的比例选档（screenFit），下次加屏按新的建
    private func reshape(_ id: DisplayID) async {
        guard await displays.reshape(id, to: fit) else {
            Log.warn("手机屏 #\(id) 没能换成新比例（\(fit)），下次加屏时按新的建")
            state.notice = .reshapeFailed
            return
        }
        state.notice = .reshaped
        guard var p = placement else { return }
        // 窗口要的档位按新比例从基准宽度重新找；忘掉上次挪完的样子，露出来时一定重新铺
        p.width = fit.baseWidth
        p.settled = nil
        if !state.listVisible {
            Log.info("换了比例，\(p.window.label) 按新比例重新铺满")
            await fill(&p, on: id)
        }
        placement = p
    }

    private func recheck() async {
        if state.listVisible { await matchWidth() } else { await refill(because: "屏幕配置变了") }
    }

    /// 窗口没铺好就重新铺：手机屏不在它那一档（刚从列表回来、换档没成、系统改了模式），
    /// 或者窗口被挪动、撑大了（换档时系统会挪它；终端类 App 调字号时会按行列数撑大窗口）。
    /// 跟上次挪完的样子比，不跟可放区域比：比最宽一档还宽的窗口本来就铺不满，再挪也一样
    private func refill(because reason: String) async {
        guard let id = display?.id, var p = placement, let frame = await windows.look(p.window.key)?.frame else { return }
        let moved = p.settled.map { !frame.matches($0) } ?? true
        guard moved || displays.width(id) != p.width else { return }
        let what = moved ? "变成了 \(frame.short)" : "要的 \(p.width) 宽不是手机屏现在这一档"
        Log.info("\(reason)，\(p.window.label) \(what)，重新铺满")
        await fill(&p, on: id)
        placement = p
    }

    // MARK: 屏幕适配

    /// 手机屏此刻的比例：选档只能在屏上登记的档位里选。换比例还没轮到、或者没换成时，它和 fit 不一样
    private var screenFit: ScreenFit {
        display.flatMap { displays.fit($0.id) } ?? fit
    }

    /// 手机屏该用哪一档：露着列表（或没放窗口）是基准宽度，放着窗口是它那一档
    private var wantedWidth: Int {
        guard let p = placement, !state.listVisible else { return screenFit.baseWidth }
        return p.width
    }

    /// 让手机屏跟上该用的那一档
    private func matchWidth() async {
        guard let id = display?.id else { return }
        await switchWidth(id, to: wantedWidth)
    }

    private func switchWidth(_ id: DisplayID, to width: Int) async {
        if displays.width(id) != width { await displays.setWidth(id, width) }
    }

    /// 手机屏换到窗口那一档，把窗口铺满。铺不满（App 限定了最小尺寸）就按它实际的大小换到装得下的一档再铺。
    /// 换档没成时屏还是原来那一档，算出来的还是这一档，不会一直往上换。返回最后挪到的位置；挪不动（窗口关了、App 没响应）返回 nil
    @discardableResult
    private func fill(_ p: inout Placement, on id: DisplayID) async -> CGRect? {
        await switchWidth(id, to: p.width)
        guard let area = displays.windowArea(id), let got = await moveOntoPhone(p.window, to: area) else { return nil }
        p.settled = got
        // App 关窗时存下的就是这个大小：窗口在 Snug 之外没了，凭它认出回来的是不是它
        p.record.filled = got
        write(p.record)
        if p.asking {
            state.closeButton = nil
        } else {
            state.closeButton = await windows.closeButton(p.window.key).map { CloseButton(frame: $0, window: p.window.key.id, windowFrame: got) }
        }
        // 窗口落到了区域原点、只是尺寸被夹住，才是 App 限定了最小尺寸；没挪过去（App 不认挪动）就不按它的大小换档
        let placed = abs(got.minX - area.minX) < 2 && abs(got.minY - area.minY) < 2
        guard placed, let current = displays.width(id) else { return got }
        let width = screenFit.width(toFit: got.size, in: area.size, at: current)
        guard width > current, width != p.width else { return got }
        Log.info("\(p.window.label) 在 \(current) 宽的手机屏上铺不满（App 限定了最小尺寸，实际 \(got.short)），换到 \(width) 宽")
        p.width = width
        return await fill(&p, on: id)
    }

    /// 有些 App 的窗口从下方或远处的屏幕直达手机屏时，会把目标位置夹回原来的屏幕。
    /// 先试直达；位置没过去就把窗口放到主屏中间，让 App 更新自己认定的当前屏幕，再试一次。
    /// 最终原点仍不对就交回失败，不能把还留在别处的窗口当成已经放上手机屏。
    private func moveOntoPhone(_ window: WindowInfo, to target: CGRect) async -> CGRect? {
        guard let first = await windows.move(window.key, to: target) else { return nil }
        if Self.sameOrigin(first, target) { return first }
        guard let main = displays.mainArea() else {
            Log.warn("\(window.label) 直达手机屏后位置没过去（实际 \(first.short)），又读不到主屏，无法中转")
            return nil
        }
        let size = CGSize(width: min(first.width, main.width), height: min(first.height, main.height))
        let staging = CGRect(x: (main.midX - size.width / 2).rounded(), y: (main.midY - size.height / 2).rounded(),
                             width: size.width, height: size.height)
        guard let staged = await windows.move(window.key, to: staging),
              main.contains(CGPoint(x: staged.midX, y: staged.midY)) else {
            Log.warn("\(window.label) 直达手机屏后位置没过去（实际 \(first.short)），主屏中转也失败")
            return nil
        }
        Log.info("\(window.label) 直达手机屏后位置没过去（实际 \(first.short)），已经过主屏中转再试")
        guard let final = await windows.move(window.key, to: target), Self.sameOrigin(final, target) else {
            Log.warn("\(window.label) 经过主屏中转仍挪不上手机屏")
            return nil
        }
        return final
    }

    private static func sameOrigin(_ frame: CGRect, _ target: CGRect) -> Bool {
        abs(frame.minX - target.minX) < 2 && abs(frame.minY - target.minY) < 2
    }

    /// 收起列表、露出手机屏上的窗口：先换到它那一档、重新铺满，再收列表、激活它。
    /// 换档时列表还盖着，手机上看不到窗口被挪来挪去
    private func reveal() async {
        guard let id = display?.id, let p = placement else { return }
        // 先换档：App 一时读不到时 refill 什么都不做，档位也得对；换档触发的复查会在 App 恢复后补铺
        await switchWidth(id, to: p.width)
        await refill(because: "回到窗口")
        state.listVisible = false
        await windows.focus(p.window.key)
    }

    // MARK: 放窗口

    /// zoom 为 false：放的是在问用户的窗口（对话框、挂着 sheet 的文档），不调字号，按键会被对话框挡下
    private func place(_ window: WindowInfo, zoom: Bool = true) async {
        let started = timeline.now
        guard let id = readyDisplay(for: "放 \(window.label)") else {
            state.notice = .screenNotReady
            return
        }
        if placement?.window.key == window.key {
            await reveal()
            return
        }
        // 先确认要放的窗口够得着，再动手机屏上现在那个：点到刚关掉的卡片，不能先把现在的拆了、两头落空
        guard await reach(window) != nil else { return }
        // 原来那个、或上次没放回去的那个放不回去（App 卡住）就不放：两个窗口会叠在手机屏上，还原记录也只记得住一个
        if let p = placement, await !returnToOriginal(p) {
            Log.warn("\(p.window.label) 放不回去，先不换成 \(window.label)")
            state.notice = .windowUnresponsive(app: p.window.app)
            return
        }
        if let stuck = await putBackLeftover() {
            Log.warn("\(stuck.label) 还放不回去，先不放 \(window.label)")
            state.notice = .windowUnresponsive(app: stuck.app)
            return
        }
        // 放回别的窗口可能动到它（上次没放回去的就是它），重新读
        guard let look = await reach(window) else { return }
        let known = Set(await windows.shownWindows(of: window.key.pid).map(\.key)).subtracting([window.key])
        // 先记账再动手。全屏的窗口这时读到的是全屏的位置，崩溃后按它放回再恢复全屏也对。
        // 它是留下的账的窗口、原样回来了（手机屏上关掉又在手机上重开）：接着用那笔账，原位还是当初的，字号按带回来的算
        let owed = leftBehind.match(window, frame: look.frame)
        let record = owed.map { leftBehind.entries[$0].returned(as: window.key) } ?? PhoneRecord(
            window: window.key, app: window.app, label: window.label, original: originalFrame(look.frame, offPhone: id),
            wasFullScreen: look.fullScreen, wasMinimized: look.minimized, bundleID: window.bundleID, title: window.title)
        var next = Placement(window: window, record: record, width: screenFit.baseWidth, known: known, asking: !zoom)
        guard write(next.record) else {
            state.notice = .recordUnwritable
            return
        }
        if let owed {
            Log.info("\(window.label) 带着手机屏上的样子回来了，接着放：原位按当初的 \(record.original.short)，字号已大 \(record.zoom) 级")
            leftBehind.remove(at: owed)
            saveLeftBehind()
        }
        if look.minimized { await windows.setMinimized(window.key, false) }
        if look.fullScreen {
            await windows.setFullScreen(window.key, false)
            // 退出全屏后的位置才是它平时的位置：放回时回到这里再进全屏
            if let windowed = await windows.look(window.key)?.frame {
                next.record.original = originalFrame(windowed, offPhone: id)
                write(next.record)
            }
        }
        placement = next
        // 先按基准宽度铺，App 卡在自己的最小尺寸上时换档再铺；这时列表还盖着（「正在打开」）
        guard let got = await fill(&next, on: id) else {
            let notice = await unreachable(window)
            Log.warn("\(window.label) 挪不上手机屏（\(Self.reason(notice, gone: "刚关了"))），放回去")
            placement = nil
            await putBack(next.record)
            // 露着列表：手机屏可能停在铺的中途换过的那一档
            await matchWidth()
            state.notice = notice
            return
        }
        placement = next
        await windows.focus(window.key)
        state.listVisible = false
        let was = look.fullScreen ? "（原来全屏）" : look.minimized ? "（原来最小化）" : ""
        let took = String(format: "%.1f", timeline.now - started)
        let fill = describeFill(got, in: displays.windowArea(id), width: displays.width(id) ?? next.width)
        Log.info("\(window.label) 放上手机屏（\(took)s）：原位 \(next.record.original.short)\(was)，\(fill)")

        // 带着字号回来的不重复放大，只补差的那几级
        let steps = zoomBook.steps(for: window.bundleID, default: defaultZoom) - next.record.zoom
        guard zoom, steps != 0 else { return }
        // 窗口已经在手机屏上了，剩下的只是调字号
        state.work = .zooming
        await timeline.sleep(Self.settleDelay)
        await changeZoom(by: steps)
    }

    /// 原位：落在手机屏上的（App 按上次记住的位置把窗口开在了手机屏上）改成主屏居中，屏一撤那个位置就不存在了
    private func originalFrame(_ frame: CGRect, offPhone id: DisplayID) -> CGRect {
        guard let phone = displays.bounds(id), phone.contains(CGPoint(x: frame.midX, y: frame.midY)),
              let main = displays.mainArea() else { return frame }
        let size = CGSize(width: min(frame.width, main.width), height: min(frame.height, main.height))
        return CGRect(x: (main.midX - size.width / 2).rounded(), y: (main.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    // MARK: 打开、退出 App，关窗口

    /// 打开 App（newWindowIn 给了就是给这个进程新建窗口），等它此刻在屏上、之前不在屏上的标准窗口出来，放上手机屏。
    /// 认「之前不在屏上」而不认新编号：唤回时 App 常常重新显示原来那个窗口，编号不变
    private func openWindow(of app: AppInfo, newWindowIn running: Int32?) async {
        let started = timeline.now
        guard readyDisplay(for: "打开 \(app.name)") != nil else {
            state.notice = .screenNotReady
            return
        }
        let known = if let running { running } else { await apps.pid(of: app) }
        if let known, state.quitting.contains(known) { return Log.info("\(app.name) 正在退出，不打开") }
        var before: Set<WindowKey> = []
        if let known { before = Set(await windows.shownWindows(of: known).map(\.key)) }
        let pid: Int32
        if let running {
            guard await apps.newWindow(pid: running) else {
                Log.warn("\(app.name) 菜单里没有「新建窗口」（或没响应），没法新建窗口")
                state.notice = .noNewWindow(app: app.name)
                return
            }
            pid = running
        } else {
            guard let opened = await apps.open(app) else {
                Log.warn("打不开 \(app.name)（\(app.path ?? app.bundleID)）")
                state.notice = .openFailed(app: app.name)
                return
            }
            pid = opened
        }
        let wait = known == nil ? Self.launchWait : Self.windowWait
        switch await awaitWindow(of: pid, excluding: before, within: wait) {
        case .appeared(let window):
            let how = running != nil ? "新建窗口" : known == nil ? "启动" : "唤回"
            Log.info("\(app.name) \(how)后 \(String(format: "%.1f", timeline.now - started))s 出现 \(window.label)，放上手机屏")
            state.work = .placing(window)
            await place(window)
        case .appQuit:
            Log.warn("\(app.name) 打开后又退出了，没有窗口")
            state.notice = .openFailed(app: app.name)
        case .timedOut:
            Log.warn("\(app.name) 打开了，但 \(Int(wait))s 内没有可显示的窗口")
            state.notice = .noWindow(app: app.name)
        case .abandoned:
            Log.info("不要手机屏了，不再等 \(app.name) 的窗口")
        }
    }

    private enum Awaited {
        case appeared(WindowInfo)
        /// App 中途退了（启动就崩、自己退了）
        case appQuit
        case timedOut
        /// 不要手机屏了（远程结束、Snug 退出）：排在后面的撤屏不能干等
        case abandoned
    }

    private func awaitWindow(of pid: Int32, excluding known: Set<WindowKey>, within seconds: TimeInterval) async -> Awaited {
        let deadline = timeline.now + seconds
        while wanted {
            if let window = await windows.shownWindows(of: pid).first(where: { !known.contains($0.key) }) { return .appeared(window) }
            guard await apps.isRunning(pid: pid) else { return .appQuit }
            guard timeline.now < deadline else { return .timedOut }
            await timeline.sleep(Self.windowPoll)
        }
        return .abandoned
    }

    /// 盯着请它退出的 App：退完了就好；在问就放上手机屏等人答，答了取消就不再盯；
    /// 等满了还没退、也没在问，提示可以强制退出，之后再低频看一阵：它自己退了，提示就撤掉
    private func watchQuit(_ app: RunningApp) {
        watch(.quit(app.pid)) {
            defer { self.state.quitting.remove(app.pid) }
            let answer = await self.awaitAnswer(from: app.pid, within: Self.quitWait, done: { await !self.apps.isRunning(pid: app.pid) })
            guard !Task.isCancelled else { return }
            switch answer {
            case .done:
                Log.info("\(app.app.name) 已退出")
                self.onGone?(.app(app.pid))
            case .canceled: Log.info("\(app.app.name) 没退出（对话框里点了取消）")
            case .stalled:
                Log.warn("\(app.app.name) 请它退出 \(Int(Self.quitWait))s 后还在，也没有对话框")
                let stalled = Notice.quitStalled(app: app.app.name, pid: app.pid)
                self.state.notice = stalled
                self.state.quitting.remove(app.pid)
                let until = self.timeline.now + Self.stalledFollow
                while !Task.isCancelled, self.timeline.now < until, await self.apps.isRunning(pid: app.pid) {
                    await self.timeline.sleep(Self.stalledPoll)
                }
                guard !Task.isCancelled, await !self.apps.isRunning(pid: app.pid) else { return }
                Log.info("\(app.app.name) 后来自己退出了")
                self.onGone?(.app(app.pid))
                if self.state.notice == stalled { self.state.notice = nil }
            }
        }
    }

    /// 盯着请它关掉的窗口，同退出；等满了还在、也没在问，提示无响应。
    /// hides：按关闭前它在屏上，那么不在屏上了（飞书、微信关成了隐藏）也算关上
    private func watchClose(_ window: WindowInfo, hides: Bool) {
        watch(.close(window.key)) {
            defer { self.state.closing.remove(window.key) }
            let answer = await self.awaitAnswer(from: window.key.pid, within: Self.closeWait) {
                guard await self.windows.exists(window.key) else { return true }
                guard hides else { return false }
                return await !self.windows.isShown(window.key)
            }
            guard !Task.isCancelled else { return }
            switch answer {
            case .done:
                Log.info("\(window.label) 已关闭")
                self.onGone?(.window(window.key))
            case .canceled: Log.info("\(window.label) 没关（对话框里点了取消）")
            case .stalled:
                Log.warn("\(window.label) 请它关掉 \(Int(Self.closeWait))s 后还在，也没有对话框")
                self.state.notice = .windowUnresponsive(app: window.app)
            }
        }
    }

    /// 另起一个任务盯着，不占队。同一件事再盯一次（提示强制退出后又点了退出）先停掉旧的；撤屏时一起取消
    private func watch(_ id: Watched, _ body: @escaping @MainActor () async -> Void) {
        watches[id]?.cancel()
        watches[id] = Task {
            await body()
            // 取消的已经被换掉或清掉了，别把新的那个删了
            if !Task.isCancelled { watches[id] = nil }
        }
    }

    private func unwatch(_ id: Watched) {
        watches.removeValue(forKey: id)?.cancel()
    }

    private enum Answer {
        case done, canceled, stalled
    }

    /// 发出退出、关窗请求之后等结果：done 为真就是成了；App 在问用户（「要存储吗」「还有进程在跑」，
    /// 可能一连问好几次：多个未存储的文稿先问「要先检查吗」，再逐个问）就把问的窗口放上手机屏，问着就一直等；
    /// 问完了 done 还不成立，就是点了取消；一直没动静，等满 seconds 算卡住
    private func awaitAnswer(from pid: Int32, within seconds: TimeInterval, done: () async -> Bool) async -> Answer {
        let deadline = timeline.now + seconds
        var asked: WindowKey?
        var answeredAt: TimeInterval?
        while !Task.isCancelled {
            if await done() { return .done }
            if let asking = await windows.askingWindow(of: pid) {
                answeredAt = nil
                if asking.key != asked {
                    asked = asking.key
                    Log.info("\(asking.app) 在问，把 \(asking.label) 放上手机屏")
                    await placeAsking(asking)
                }
            } else if asked != nil {
                let at = answeredAt ?? timeline.now
                answeredAt = at
                if timeline.now - at >= Self.answerGrace { return .canceled }
            } else if timeline.now >= deadline {
                return .stalled
            }
            await timeline.sleep(Self.watchPoll)
        }
        return .canceled
    }

    /// 排进队里再放，状态也轮到它时才改：不然会被前面那个动作结束时的 work = nil 冲掉
    private func placeAsking(_ window: WindowInfo) async {
        guard !Task.isCancelled else { return }
        await lane.run {
            self.state.notice = nil
            self.state.work = .placing(window)
            await self.place(window, zoom: false)
            self.state.work = nil
        }.value
    }

    /// 放回原位、回到 App 资源库，返回放回去了没有。restoringState 为 false 时不恢复全屏、最小化（马上要关的窗口）。
    /// 没放回去时窗口还在手机屏上，照旧算放着（字号按实际缩回了多少算），还原记录也留着
    private func returnToOriginal(_ p: Placement, restoringState: Bool = true) async -> Bool {
        if let left = await putBack(p.record, restoringState: restoringState) {
            var p = p
            p.record = left
            placement = p
            return false
        }
        placement = nil
        state.listVisible = true
        return true
    }

    /// 按记录放回：缩回字号（窗口还在手机屏上、还是它 App 的当前窗口；缩完马上记账）→ 挪回原位 →
    /// 原来全屏的恢复全屏、原来最小化的再最小化。放回了就销账、窗口确实没了就转成留下的账，返回 nil；
    /// 窗口还在却缩不回、挪不动（App 没响应、没有权限）就留着记录（下次放窗口或下次启动再放），返回留下的这条
    @discardableResult
    private func putBack(_ record: PhoneRecord, restoringState: Bool = true) async -> PhoneRecord? {
        var record = record
        let zoom = record.zoom
        if zoom != 0 {
            // 缩不回就先不挪：挪回原位就销账了，多出来的字号再也没人缩
            guard await windows.zoom(record.window, steps: -zoom) else { return await stuckOrGone(record, "缩不回字号") }
            record.zoom = 0
            write(record)
        }
        guard let got = await windows.move(record.window, to: record.original) else {
            return await stuckOrGone(record, "挪不动")
        }
        if restoringState, record.wasFullScreen {
            await timeline.sleep(Self.settleDelay)
            await windows.setFullScreen(record.window, true)
        } else if restoringState, record.wasMinimized {
            await windows.setMinimized(record.window, true)
        }
        settleRecord()
        if got.matches(record.original) {
            let restored = !restoringState ? "" : record.wasFullScreen ? "并恢复全屏" : record.wasMinimized ? "并最小化" : ""
            Log.info("\(record.label) 已放回原位\(restored)\(zoom != 0 ? "，字号缩回 \(zoom) 级" : "")")
        } else {
            Log.warn("\(record.label) 放回没对上：目标 \(record.original.short)，实际 \(got.short)")
        }
        return nil
    }

    /// 上次没放回去的窗口（Snug 崩溃，或 App 卡住没放成）：按还原记录放回去。
    /// 放下一个窗口之前必须先做，不然新记录会把它的原位和字号永远盖掉。返回仍然放不回去的那条
    @discardableResult
    private func putBackLeftover() async -> PhoneRecord? {
        guard placement == nil, let record = ledger.pending() else { return nil }
        guard await windows.exists(record.window) else {
            Log.info("还原记录里的 \(record.label) 已经不在了（App 退出或窗口关了），等它回来再还")
            await leaveBehind(record)
            return nil
        }
        Log.info("\(record.label) 上次没放回去，现在放回 \(record.original.short)")
        return await putBack(record)
    }

    /// 放回时有一步做不了：窗口还在就留着记录、返回这条，确实没了就转成留下的账
    private func stuckOrGone(_ record: PhoneRecord, _ what: String) async -> PhoneRecord? {
        if await windows.exists(record.window) {
            Log.warn("\(record.label) 还在，但\(what)（App 没响应或没有辅助功能权限），还原记录留着，稍后再放回")
            return record
        }
        Log.info("\(record.label) 已经关了，等它回来再还")
        await leaveBehind(record)
        return nil
    }

    // MARK: 留下的账

    /// 窗口在 Snug 之外没了：账不销，转成留下的账，等它带着手机屏上的大小回来再还（见 LeftBehind）。
    /// 字号按 App 存在哪处理：存在整个 App 里的（Zed）马上从它别的窗口缩回；会被 App 记住、回来时又认不出的（VS Code
    /// 按工作区记，重开时大小可能被重设），提示用户。先记下留下的账再销主记录：中途崩溃最多多一笔账，不会丢账
    private func leaveBehind(_ record: PhoneRecord) async {
        var record = record
        if record.zoom != 0 {
            switch ZoomBook.scope(of: record.bundleID) {
            case .app?:
                // 进程没了，内存里的字号跟着没了；还在就从它别的窗口缩回，没有别的窗口就留着，等它再出窗口时缩回
                if await !apps.isRunning(pid: record.window.pid) { record.zoom = 0 }
                else if await repayAppZoom(record) { record.zoom = 0 }
            case .workspace?:
                state.notice = .zoomLeftBehind(app: record.app, steps: record.zoom)
            case .liveWindow?, .restoredWindow?, nil:
                break
            }
        }
        leftBehind.add(LeftBehind(record: record, since: Date()))
        leftBehind.prune(now: Date())
        saveLeftBehind()
        settleRecord()
    }

    /// 字号存在整个 App 里（Zed）：从这个进程开着的另一个窗口缩回。没有别的窗口、或发不出去返回 false
    private func repayAppZoom(_ record: PhoneRecord) async -> Bool {
        guard let other = await windows.shownWindows(of: record.window.pid).first(where: { $0.key != record.window }) else {
            Log.info("\(record.label) 关了，\(record.app) 没有别的窗口，放大的 \(record.zoom) 级字号等它再出窗口时缩回")
            return false
        }
        let done = await windows.zoom(other.key, steps: -record.zoom)
        Log.info("\(record.label) 关了，字号存在整个 \(record.app) 里：从 \(other.label) 缩回 \(record.zoom) 级\(done ? "" : "，没发出去")")
        return done
    }

    /// 字号存在整个 App 里、还没缩回的（关窗时那个进程没有别的窗口）：进程又有窗口了就缩回，进程没了就不欠了
    private func repayAppWideZoom() async {
        for i in leftBehind.entries.indices where leftBehind.entries[i].zoomScope == .app && leftBehind.entries[i].record.zoom != 0 {
            let r = leftBehind.entries[i].record
            if await apps.isRunning(pid: r.window.pid) {
                // 进程还在、还没有窗口就接着等（每拍都问，先看有没有窗口，免得每拍记一条日志）
                guard await !windows.shownWindows(of: r.window.pid).isEmpty, await repayAppZoom(r) else { continue }
            }
            leftBehind.update(at: i) { $0.record.zoom = 0 }
            saveLeftBehind()
        }
    }

    /// 后台自动放上手机屏（App 换了个窗口、窗口回到了手机屏上）：用户已经开始别的动作就让出，返回 false；
    /// 照放窗口的样子显示「正在打开」，做完只清自己设的状态（用户期间点的动作已经把状态换成了它的）
    @discardableResult
    private func placeOnItsOwn(_ window: WindowInfo) async -> Bool {
        guard state.work == nil else { return false }
        state.notice = nil
        state.work = .placing(window)
        await place(window)
        if state.work == .placing(window) || state.work == .zooming { state.work = nil }
        return true
    }

    /// 刚在 Snug 之外没了的窗口，它的 App 开出了新窗口（不在放上来时就有的那些里）：接着放上来。
    /// 用户已经放了别的窗口、或等满了，就不再等
    private func followReplacement() async {
        guard let r = replaced else { return }
        guard placement == nil, timeline.now < r.until else {
            replaced = nil
            return
        }
        guard display != nil, let next = await windows.shownWindows(of: r.pid).first(where: { !r.known.contains($0.key) }) else { return }
        Log.info("\(next.app) 换了个窗口，接着放上手机屏：\(next.label)")
        if await placeOnItsOwn(next) { replaced = nil }
    }

    /// 留下的账的窗口回来了（同一个 App 的窗口带着 Snug 铺成的大小出现）：还在远程、手机屏上空着、它就开在手机屏上，
    /// 接着放着（手机上关掉又重开）；否则放回原位，字号随窗口回来的一起缩回。一次只还一笔，还不成（App 没响应）下一拍再试
    private func takeBackReturned() async {
        leftBehind.prune(now: Date())
        await repayAppWideZoom()
        // 主记录还欠着的窗口（放回时 App 卡住）归 putBackLeftover 还，别被别的账认走
        let skip = Set([placement?.window.key, ledger.pending()?.window].compactMap { $0 })
        for bundle in Set(leftBehind.entries.compactMap(\.record.bundleID)) {
            for pid in await apps.pids(bundleID: bundle) {
                // 先问窗口服务器（不经过 App，卡住的 App 也拖不慢队），大小对得上才去读辅助功能
                let sized = await windows.frames(of: pid).filter { !skip.contains($0.key) && leftBehind.awaits(bundleID: bundle, size: $0.value.size) }
                guard !sized.isEmpty else { continue }
                for window in await windows.shownWindows(of: pid) {
                    guard let frame = sized[window.key], let i = leftBehind.match(window, frame: frame) else { continue }
                    await takeBack(i, window: window, frame: frame)
                    return
                }
            }
        }
    }

    private func takeBack(_ i: Int, window: WindowInfo, frame: CGRect) async {
        if wanted, placement == nil, let id = display?.id,
           displays.bounds(id)?.contains(CGPoint(x: frame.midX, y: frame.midY)) == true {
            // 还在远程、回到了手机屏上：接着放（place 认得出这笔账，原位、字号接着用）
            await placeOnItsOwn(window)
            return
        }
        let owed = leftBehind.entries[i].returned(as: window.key)
        if owed.zoom != 0 {
            guard await windows.zoom(window.key, steps: -owed.zoom) else {
                return Log.warn("\(window.label) 带着手机屏上的样子回来了，但字号缩不回（App 没响应），下一拍再试")
            }
            // 缩完先记账：挪的时候出事，下次不会再缩一遍
            leftBehind.update(at: i) { $0.record.zoom = 0 }
            saveLeftBehind()
        }
        guard let got = await windows.move(window.key, to: owed.original) else {
            return Log.warn("\(window.label) 带着手机屏上的样子回来了，但挪不动（App 没响应），下一拍再试")
        }
        leftBehind.remove(at: i)
        saveLeftBehind()
        Log.info("\(window.label) 带着手机屏上的样子回来了，放回原位 \(got.short)\(owed.zoom != 0 ? "，字号缩回 \(owed.zoom) 级" : "")")
    }

    /// 先记账再发按键，改完核对窗口还铺不铺满。返回是否真的改了
    @discardableResult
    private func changeZoom(by delta: Int) async -> Bool {
        guard var p = placement else { return false }
        let before = p.record
        let target = (before.zoom + delta).clamped(to: ZoomBook.range)
        guard target != before.zoom else { return false }
        p.record.zoom = target
        guard write(p.record) else {
            state.notice = .recordUnwritable
            return false
        }
        guard await windows.zoom(p.window.key, steps: target - before.zoom) else {
            // 按键没发出去：记录改回原来的级数，不然还原时会多缩
            write(before)
            state.notice = await unreachable(p.window)
            Log.warn("\(p.window.label) 找不到了，字号没改")
            return false
        }
        placement = p
        Log.info("\(p.window.label) 字号比原来 \(target > 0 ? "+" : "")\(target) 级")
        await timeline.sleep(Self.settleDelay)
        // 在列表里调的字号：窗口被盖着，返回时 reveal 再补铺；这时铺会把屏换到窗口那一档
        if !state.listVisible { await refill(because: "字号改了") }
        return true
    }

    // MARK: 小工具

    private func begin(_ work: Work) {
        state.notice = nil
        state.work = work
    }

    /// 可以放窗口的手机屏；没好时写明是哪一步没好
    private func readyDisplay(for what: String) -> DisplayID? {
        guard let id = display?.id else {
            Log.warn("\(what)：没有手机屏（\(state.screen)）")
            return nil
        }
        guard displays.windowArea(id) != nil else {
            Log.warn("\(what)：读不到手机屏 #\(id) 的可放区域（屏幕组合可能还在变）")
            return nil
        }
        return id
    }

    /// 铺满了没有、用的哪一档。没铺满是 App 要的比最宽一档还宽，或者换档没成（见前面的日志）
    private func describeFill(_ got: CGRect, in area: CGRect?, width: Int) -> String {
        let screen = width == screenFit.baseWidth ? "" : "（手机屏 \(width) 宽）"
        if let area, got.matches(area) { return "已铺满\(screen)" }
        return "没铺满\(screen)，实际 \(got.short)"
    }

    /// 读要放的窗口；读不到就提示是关了还是 App 没响应
    private func reach(_ window: WindowInfo) async -> WindowLook? {
        if let look = await windows.look(window.key) { return look }
        let notice = await unreachable(window)
        Log.warn("读不到 \(window.label)（\(Self.reason(notice, gone: "已经关了"))），不放")
        state.notice = notice
        return nil
    }

    /// 读不到、挪不动的窗口：是关了，还是 App 没响应
    private func unreachable(_ window: WindowInfo) async -> Notice {
        await windows.exists(window.key) ? .windowUnresponsive(app: window.app) : .windowGone(app: window.app)
    }

    /// 日志里的原因
    private static func reason(_ notice: Notice, gone: String) -> String {
        if case .windowGone = notice { gone } else { "App 没响应或没有辅助功能权限" }
    }

    @discardableResult
    private func write(_ record: PhoneRecord) -> Bool {
        do {
            try ledger.record(record)
            return true
        } catch {
            Log.error("还原记录写不进去（\(record.label)）：\(error)")
            return false
        }
    }

    private func settleRecord() {
        do {
            try ledger.settle()
        } catch {
            // 删不掉的记录下次启动会再还原一次：窗口已经在原位，再挪一次也是原位
            Log.error("还原记录删不掉：\(error)")
        }
    }

    private func saveLeftBehind() {
        do {
            try leftBehindFile.save(leftBehind)
        } catch {
            Log.error("留下的账写不进去（left-behind.json）：\(error)")
        }
    }

    private func saveZoomBook() {
        do {
            try zoomFile.save(zoomBook)
        } catch {
            Log.error("记不住字号级数（zoom.json 写不进去）：\(error)")
        }
    }
}

/// 放在手机屏上的那个窗口：它的还原记录（写进盘里的就是这一份，不另抄字段）、它要的那一档和上次挪完的样子
private struct Placement {
    let window: WindowInfo
    var record: PhoneRecord
    /// 手机屏用哪一档（ScreenFit）：先按基准宽度，铺不满时换成装得下它的一档
    var width: Int
    /// 上次挪完的样子：比最宽一档还宽的窗口铺不满，以它为准判断窗口有没有被再挪动
    var settled: CGRect?
    /// 放上来时它的 App 已经开着的其它窗口：它在 Snug 之外没了以后，不在这里面的才算 App 换上的新窗口
    var known: Set<WindowKey> = []
    /// 在问用户的窗口（挂着「要存储吗」）：不调字号，也不拦它的关闭按钮
    var asking = false
}

/// 一条队：动作按提交顺序一个做完再做下一个
@MainActor
final class SerialLane {
    private var tail: Task<Void, Never>?

    @discardableResult
    func run(_ operation: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }

    func drain() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }
}
