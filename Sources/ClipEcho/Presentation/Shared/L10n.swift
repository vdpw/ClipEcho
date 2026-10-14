import Foundation

/// Original React and Rust message catalogs, shared by every native presentation.
enum L10n {
  static func resolve(_ preference: String) -> String {
    if ["en", "zh-CN", "zh-TW"].contains(preference) { return preference }
    for preferred in Locale.preferredLanguages {
      let parts = preferred.lowercased().replacingOccurrences(of: "_", with: "-").split(
        separator: "-")
      if parts.first == "en" { return "en" }
      if parts.first == "zh" {
        if parts.contains("hant") { return "zh-TW" }
        if parts.contains("hans") { return "zh-CN" }
        return parts.contains(where: { ["tw", "hk", "mo"].contains(String($0)) })
          ? "zh-TW" : "zh-CN"
      }
    }
    return "en"
  }

  static func string(_ key: String, language: String) -> String {
    let resolved = resolve(language)
    let index = resolved == "zh-CN" ? 1 : resolved == "zh-TW" ? 2 : 0
    guard let strings = catalog[key], strings.indices.contains(index) else { return key }
    return strings[index]
  }

  static func format(_ key: String, language: String, args: [String]) -> String {
    var selected = key
    if ["clearHistoryDescription", "menuBarItemLimitDescription"].contains(key), args.first == "0" {
      selected += ".zero"
    } else if [
      "clearHistoryDescription", "clearHistoryConfirmationDescription",
      "menuBarItemLimitDescription",
    ].contains(key), args.first == "1" {
      selected += ".one"
    } else if key == "loadedHistoryCount", args.count > 1, args[1] == "1" {
      selected += ".one"
    }
    if key == "storedItemsDescription", resolve(language) == "en", args.count >= 2 {
      func clips(_ count: String) -> String { count + (count == "1" ? " clip" : " clips") }
      return
        "Keep up to \(clips(args[0])), prioritizing pinned clips. Currently storing \(clips(args[1]))."
    }
    var output = string(selected, language: language)
    for (index, argument) in args.enumerated() {
      output = output.replacingOccurrences(of: "{\(index)}", with: argument)
    }
    return output
  }

  static func eventType(_ type: String, language: String) -> String {
    let key = "eventTypes." + type
    return catalog[key] == nil ? type.uppercased() : string(key, language: language)
  }

  private static let catalog: [String: [String]] = [
    "historyLoadError": ["Clipboard history could not be loaded.", "无法加载剪贴板历史。", "無法載入剪貼簿歷史。"],
    "error.restore_post_processing_failed": [
      "Copied, but the history or menu refresh failed.", "已复制，但历史记录或菜单刷新失败。", "已複製，但歷史記錄或選單重新整理失敗。",
    ],
    "history": ["Clipboard history", "剪贴板历史", "剪貼簿歷史"],
    "settings": ["Settings", "设置", "設定"],
    "settingsTitle": ["Settings", "设置", "設定"],
    "backToHistory": ["Back to clipboard history", "返回剪贴板历史", "返回剪貼簿歷史"],
    "search": ["Search clipboard history", "搜索剪贴板历史", "搜尋剪貼簿歷史"],
    "searchResults": ["Search Results", "搜索结果", "搜尋結果"],
    "emptyHistory": ["No clipboard events yet", "暂无剪贴板记录", "尚無剪貼簿記錄"],
    "emptyHistoryDescription": [
      "Start copying text or files and they will appear here and in the menu bar menu.",
      "开始复制文字或文件后，内容会显示在这里和菜单栏中。", "開始複製文字或檔案後，內容會顯示在這裡和選單列中。",
    ],
    "noResults": ["No matching clips", "没有匹配的记录", "沒有符合的記錄"],
    "noResultsDescription": [
      "Try a different word or clear the search field.", "尝试其他关键词，或清空搜索框。", "嘗試其他關鍵字，或清除搜尋框。",
    ],
    "pinned": ["Pinned", "已固定", "已固定"],
    "recent": ["Recent", "最近记录", "最近記錄"],
    "pin": ["Pin item", "固定项目", "固定項目"],
    "unpin": ["Unpin item", "取消固定", "取消固定"],
    "restore": ["Restore to clipboard", "恢复到剪贴板", "還原至剪貼簿"],
    "copied": ["Copied to clipboard", "已复制到剪贴板", "已複製到剪貼簿"],
    "delete": ["Delete item", "删除项目", "刪除項目"],
    "detail": ["Show Preview", "查看预览", "查看預覽"],
    "close": ["Close", "关闭", "關閉"],
    "loadMore": ["Load more", "加载更多", "載入更多"],
    "refresh": ["Refresh", "刷新", "重新整理"],
    "clips": ["clips", "条记录", "筆記錄"],
    "remote": ["From another device", "来自其他设备", "來自其他裝置"],
    "text": ["Text", "文字", "文字"],
    "image": ["Image", "图片", "圖片"],
    "file": ["File", "文件", "檔案"],
    "files": ["Files", "多个文件", "多個檔案"],
    "folder": ["Folder", "文件夹", "資料夾"],
    "folders": ["Folders", "多个文件夹", "多個資料夾"],
    "files and folders": ["Files and Folders", "文件与文件夹", "檔案與檔案夾"],
    "png": ["PNG Image", "PNG 图片", "PNG 圖片"],
    "tiff": ["TIFF Image", "TIFF 图片", "TIFF 圖片"],
    "jpeg": ["JPEG Image", "JPEG 图片", "JPEG 圖片"],
    "jpg": ["JPEG Image", "JPEG 图片", "JPEG 圖片"],
    "gif": ["GIF Image", "GIF 图片", "GIF 圖片"],
    "webp": ["WebP Image", "WebP 图片", "WebP 圖片"],
    "heic": ["HEIC Image", "HEIC 图片", "HEIC 圖片"],
    "heif": ["HEIF Image", "HEIF 图片", "HEIF 圖片"],
    "bmp": ["BMP Image", "BMP 图片", "BMP 圖片"],
    "video": ["Video", "视频", "影片"],
    "html": ["Formatted Text", "格式化文本", "格式化文字"],
    "rtf": ["Rich Text", "富文本", "富文字"],
    "unsupported": ["Clipboard Item", "剪贴板记录", "剪貼簿記錄"],
    "preview": ["Clipboard Preview", "剪贴板预览", "剪貼簿預覽"],
    "previewUnavailable": ["No preview is available for this format.", "此格式暂无预览。", "此格式暫無預覽。"],
    "previewBounded": [
      "Preview is limited to keep the app responsive. The complete item is restored when copied.",
      "预览已限制大小以保持流畅。复制时仍会还原完整内容。", "預覽已限制大小以保持流暢。複製時仍會還原完整內容。",
    ],
    "deletePinnedTitle": ["Delete this pinned item?", "删除此固定项目？", "刪除此固定項目？"],
    "deletePinnedMessage": [
      "This item is pinned. Deleting it will permanently remove it from clipboard history.",
      "此项目已固定，删除后将从剪贴板历史中永久移除。", "此項目已固定，刪除後將從剪貼簿歷史中永久移除。",
    ],
    "compactDeleteMessage": [
      "In compact mode, all items with the same text will also be deleted.",
      "精简模式下，所有具有相同文本的项目也会一并删除。", "精簡模式下，所有具有相同文字的項目也會一併刪除。",
    ],
    "cancel": ["Cancel", "取消", "取消"],
    "general": ["General", "通用", "一般"],
    "appearance": ["Appearance", "外观", "外觀"],
    "clipboard": ["Clipboard", "剪贴板", "剪貼簿"],
    "menuBar": ["Menu Bar", "菜单栏", "選單列"],
    "generalDescription": ["Language and startup preferences.", "管理语言与登录启动偏好。", "管理語言與登入啟動偏好。"],
    "appearanceDescription": [
      "Choose how ClipEcho looks.", "选择 ClipEcho 的窗口外观。", "選擇 ClipEcho 的視窗外觀。",
    ],
    "clipboardDescription": [
      "Manage capture behavior and retained history.", "管理采集行为与历史保留规则。", "管理擷取行為與歷史保留規則。",
    ],
    "menuBarDescription": [
      "Quick access to clipboard history from your menu bar.", "从菜单栏快速访问剪贴板历史。", "從選單列快速存取剪貼簿歷史。",
    ],
    "language": ["Language", "语言", "語言"],
    "system": ["System Default", "跟随系统", "跟隨系統"],
    "launchAtLogin": ["Launch at login", "登录时启动", "登入時啟動"],
    "theme": ["Color theme", "颜色主题", "顏色主題"],
    "light": ["Light", "浅色", "淺色"],
    "dark": ["Dark", "深色", "深色"],
    "behavior": ["Capture & behavior", "采集与行为", "擷取與行為"],
    "compact": ["Compact mode", "精简模式", "精簡模式"],
    "compactDescription": [
      "Only recognizable text is kept; image and file clips are ignored.", "只保留可识别的文字；图片和文件不会被保存。",
      "只保留可辨識的文字；圖片和檔案不會被儲存。",
    ],
    "restoreToTop": ["Move restored items to top", "将恢复的项目移到顶部", "將還原的項目移至頂端"],
    "restoreToTopDescription": [
      "Restored clips keep their current order.", "恢复剪贴板内容后会保留当前顺序。", "還原剪貼簿內容後會保留目前順序。",
    ],
    "storage": ["Storage", "存储", "儲存"],
    "maxItems": ["Stored items", "存储数量", "儲存數量"],
    "maxItemsHelp": [
      "Over the item limit, the oldest unpinned clips are removed. Pinned clips are always kept.",
      "超出数量上限时，清理最旧的未固定记录。固定记录始终保留。", "超出數量上限時，清理最舊的未固定記錄。固定記錄始終保留。",
    ],
    "historyBytes": ["History storage budget", "历史记录存储预算", "歷史記錄儲存預算"],
    "historyBytesHelp": [
      "Maximum local history size in MiB (16–4096). Oldest unpinned items are removed first.",
      "本地历史记录的最大大小（MiB，16–4096）。超出后会先删除最旧的未固定项目。", "本機歷史記錄的最大大小（MiB，16–4096）。超出後會先刪除最舊的未固定項目。",
    ],
    "eventBytes": ["Maximum item size", "单条大小上限", "單筆大小上限"],
    "eventBytesHelp": [
      "Limits each new clip's stored data. Oversized clips keep plain text when it fits; otherwise they are skipped. Existing history is kept. Larger clips use more memory; previews stay limited.",
      "限制新记录的存储大小。超出时，若纯文本符合上限则仅保留纯文本，否则跳过。已有记录保留。大条目会增加内存占用，预览大小另有限制。",
      "限制新記錄的儲存大小。超出時，若純文字符合上限則僅保留純文字，否則略過。既有記錄保留。大項目會增加記憶體用量，預覽大小另有限制。",
    ],
    "apply": ["Apply", "应用", "套用"],
    "invalidNumber": [
      "Enter a whole number within the allowed range.", "请输入允许范围内的整数。", "請輸入允許範圍內的整數。",
    ],
    "reduceHistoryTitle": ["Reduce the history limit?", "降低历史上限？", "降低歷史上限？"],
    "reduceHistoryMessage": [
      "Older unpinned clips may be permanently deleted to meet the new limit. Pinned clips are kept.",
      "可能永久删除较早的未固定记录，以满足新上限。固定记录会保留。", "可能永久刪除較早的未釘選記錄，以符合新上限。釘選記錄會保留。",
    ],
    "storageDirectory": ["Storage location", "存储位置", "儲存位置"],
    "change": ["Change…", "更改…", "更改…"],
    "chooseDirectory": ["Choose Storage Directory", "选择存储目录", "選擇儲存目錄"],
    "move": ["Move", "移动", "移動"],
    "clearUnpinned": ["Clear unpinned", "清空未固定", "清除未固定"],
    "clearAll": ["Clear unpinned", "清空未固定", "清除未固定"],
    "clearUnpinnedTitle": ["Clear unpinned clipboard history?", "清空未固定的剪贴板历史？", "清除未固定的剪貼簿歷史？"],
    "clearUnpinnedMessage": [
      "All unpinned clips will be permanently removed. Pinned clips are kept.",
      "所有未固定记录将永久删除。固定记录会保留。", "所有未釘選記錄將永久刪除。釘選記錄會保留。",
    ],
    "clearAllTitle": [
      "Delete all history, including pinned clips?", "删除全部历史，包括固定记录？", "刪除全部歷史，包括釘選記錄？",
    ],
    "clearAllMessage": [
      "Every clip, including pinned clips, will be permanently removed. This cannot be undone.",
      "所有记录（包括固定记录）将永久删除。此操作无法撤销。", "所有記錄（包括釘選記錄）將永久刪除。此操作無法復原。",
    ],
    "clear": ["Clear History", "清除历史", "清除歷史"],
    "showInMenuBar": ["Show in menu bar", "在菜单栏中显示", "在選單列中顯示"],
    "menuLimit": ["Tray menu items", "托盘菜单条目数", "選單列選單項目數"],
    "menuLimitHelp": [
      "0–1,000; zero shows all retained items (up to 1,000).", "0–1,000；0 表示显示全部保留的记录（最多 1,000 条）。",
      "0–1,000；0 表示顯示全部保留的記錄（最多 1,000 筆）。",
    ],
    "storageUsage": ["Storage usage", "存储用量", "儲存用量"],
    "quit": ["Quit ClipEcho", "退出 ClipEcho", "結束 ClipEcho"],
    "showHistory": ["Open history", "打开历史记录", "開啟歷史記錄"],
    "about": ["About ClipEcho", "关于 ClipEcho", "關於 ClipEcho"],
    "errorTitle": [
      "ClipEcho could not complete this action", "ClipEcho 无法完成此操作", "ClipEcho 無法完成此操作",
    ],
    "storageError": [
      "Clipboard storage is unavailable, or the requested change could not be saved.",
      "剪贴板存储不可用，或无法保存此更改。", "剪貼簿儲存無法使用，或無法儲存此變更。",
    ],
    "operationError": [
      "The operation could not be completed. Try again.", "无法完成此操作，请重试。", "無法完成此操作，請再試一次。",
    ],
    "readOnly": [
      "History is open for inspection. Reopen ClipEcho normally to make changes.",
      "历史当前为查看模式。请正常重新打开 ClipEcho 以进行更改。", "歷史目前為檢視模式。請正常重新開啟 ClipEcho 以進行變更。",
    ],
    "captureError": [
      "A clipboard item could not be saved. Check your storage settings.", "无法保存一条剪贴板记录，请检查存储设置。",
      "無法儲存一筆剪貼簿記錄，請檢查儲存設定。",
    ],
    "services": ["Services", "服务", "服務"],
    "hide": ["Hide ClipEcho", "隐藏 ClipEcho", "隱藏 ClipEcho"],
    "hideOthers": ["Hide Others", "隐藏其他", "隱藏其他"],
    "showAll": ["Show All", "全部显示", "全部顯示"],
    "edit": ["Edit", "编辑", "編輯"],
    "undo": ["Undo", "撤销", "還原"],
    "cut": ["Cut", "剪切", "剪下"],
    "copy": ["Copy", "复制", "複製"],
    "paste": ["Paste", "粘贴", "貼上"],
    "selectAll": ["Select All", "全选", "全選"],
    "window": ["Window", "窗口", "視窗"],
    "minimize": ["Minimize", "最小化", "縮到最小"],
    "retry": ["Retry", "重试", "重試"],
    "captureRejected": [
      "A clipboard item was not saved because it exceeded a safety limit or requested privacy.",
      "由于内容超出安全限制或请求保护隐私，一条剪贴板内容未被保存。", "由於內容超出安全限制或要求保護隱私，一筆剪貼簿內容未被儲存。",
    ],
    "ok": ["OK", "好", "好"],
    "backToHistoryShort": ["Back to History", "返回主界面", "返回主畫面"],
    "loadingSettings": ["Loading settings...", "正在加载设置...", "正在載入設定..."],
    "starting": ["Starting ClipEcho...", "正在启动 ClipEcho...", "正在啟動 ClipEcho..."],
    "storedItems": ["Stored items", "存储数量", "儲存數量"],
    "settingHelp": ["{0} help", "{0}说明", "{0}說明"],
    "storedItemsHelp": [
      "Over the item limit, the oldest unpinned clips are removed. Pinned clips are always kept.",
      "超出数量上限时，清理最旧的未固定记录。固定记录始终保留。", "超出數量上限時，清理最舊的未固定記錄。固定記錄始終保留。",
    ],
    "historyBudgetHelp": [
      "Over the storage limit, the oldest unpinned clips are removed. Pinned clips stay; each clip can use up to {0}.",
      "超出容量时，清理最旧的未固定记录。固定记录保留；单条最多 {0}。", "超出容量時，清理最舊的未固定記錄。固定記錄保留；單筆最多 {0}。",
    ],
    "storedItemsDescription": [
      "Keep up to {0} clips, prioritizing pinned clips. Currently storing {1} clips.",
      "数量上限 {0} 条，优先保留固定项目。目前已存储 {1} 条。", "數量上限 {0} 筆，優先保留固定項目。目前已儲存 {1} 筆。",
    ],
    "storedItemsDescription.one": [
      "Keep up to 1 clip, prioritizing pinned clips. Currently storing {1} clips.",
      "数量上限 1 条，优先保留固定项目。目前已存储 {1} 条。", "數量上限 1 筆，優先保留固定項目。目前已儲存 {1} 筆。",
    ],
    "historyStorageUsage": [
      "History uses {0} of the {1} local storage budget.", "历史记录已使用 {0}，本地存储预算为 {1}。",
      "歷史記錄已使用 {0}，本機儲存預算為 {1}。",
    ],
    "maximumEventSize": [
      "A single clipboard item can use up to {0}.", "单条剪贴板内容最多可使用 {0}。", "單筆剪貼簿內容最多可使用 {0}。",
    ],
    "historyBudget": ["History storage budget", "历史记录存储预算", "歷史記錄儲存預算"],
    "historyBudgetDescription": [
      "Maximum local history size in MiB (16–4096). Oldest unpinned items are removed first.",
      "本地历史记录的最大大小（MiB，16–4096）。超出后会先删除最旧的未固定项目。", "本機歷史記錄的最大大小（MiB，16–4096）。超出後會先刪除最舊的未固定項目。",
    ],
    "historyBudgetError": [
      "Enter a whole number from 16 to 4096 MiB.", "请输入 16 到 4096 之间的整数（MiB）。",
      "請輸入 16 到 4096 之間的整數（MiB）。",
    ],
    "eventBudget": ["Maximum item size", "单条大小上限", "單筆大小上限"],
    "eventBudgetHelp": [
      "Limits each new clip's stored data. Oversized clips keep plain text when it fits; otherwise they are skipped. Existing history is kept. Larger clips use more memory; previews stay limited.",
      "限制新记录的存储大小。超出时，若纯文本符合上限则仅保留纯文本，否则跳过。已有记录保留。大条目会增加内存占用，预览大小另有限制。",
      "限制新記錄的儲存大小。超出時，若純文字符合上限則僅保留純文字，否則略過。既有記錄保留。大項目會增加記憶體用量，預覽大小另有限制。",
    ],
    "eventBudgetError": [
      "Enter a whole number from 1 to 256 MiB.", "请输入 1 到 256 之间的整数（MiB）。",
      "請輸入 1 到 256 之間的整數（MiB）。",
    ],
    "storageLimitError": [
      "Enter a whole number between 1 and 1000.", "请输入 1 到 1000 之间的整数。", "請輸入 1 到 1000 之間的整數。",
    ],
    "systemDefault": ["System Default", "跟随系统", "跟隨系統"],
    "languageDescriptionSystem": [
      "Use this computer's closest supported language ({0}).", "根据这台电脑的语言设置，使用最接近的受支持语言（{0}）。",
      "依照這台電腦的語言設定，使用最接近的支援語言（{0}）。",
    ],
    "languageDescriptionManual": [
      "Use this language in ClipEcho instead of the system language.", "在 ClipEcho 中使用此语言，不跟随系统语言。",
      "在 ClipEcho 中使用此語言，不跟隨系統語言。",
    ],
    "compactMode": ["Compact mode", "精简模式", "精簡模式"],
    "compactModeEnabled": [
      "Only recognizable text is kept; image and file clips are ignored.", "只保留可识别的文字；图片和文件不会被保存。",
      "只保留可辨識的文字；圖片和檔案不會被儲存。",
    ],
    "compactModeDisabled": [
      "Keep all supported clipboard content and formatting.", "保留所有支持的剪贴板内容和格式。",
      "保留所有支援的剪貼簿內容和格式。",
    ],
    "launchAtLoginEnabled": ["Starts quietly when you sign in.", "登录后会静默启动。", "登入後會靜默啟動。"],
    "launchAtLoginDisabled": ["Does not start automatically.", "不会自动启动。", "不會自動啟動。"],
    "launchAtLoginLoading": ["Checking login startup status...", "正在检查登录启动状态...", "正在檢查登入啟動狀態..."],
    "launchAtLoginReadError": [
      "Could not verify the login startup setting. Try reopening Settings.",
      "无法确认登录启动设置。请重新打开“设置”后再试。", "無法確認登入啟動設定。請重新開啟「設定」後再試。",
    ],
    "launchAtLoginUpdateError": [
      "Could not update the login startup setting. The previous setting was restored.",
      "无法更新登录启动设置，已恢复之前的设置。", "無法更新登入啟動設定，已還原先前的設定。",
    ],
    "moveRestoredItemsToTop": ["Move restored items to top", "将恢复的项目移到顶部", "將還原的項目移至頂端"],
    "restoreOrderingEnabled": [
      "Restored clips refresh history order.", "恢复剪贴板内容后会更新历史记录顺序。", "還原剪貼簿內容後會更新歷史記錄順序。",
    ],
    "restoreOrderingDisabled": [
      "Restored clips keep their current order.", "恢复剪贴板内容后会保留当前顺序。", "還原剪貼簿內容後會保留目前順序。",
    ],
    "menuBarEnabled": [
      "Recent clips are available from the tray menu.", "可从菜单栏访问最近的剪贴板内容。", "可從選單列存取最近的剪貼簿內容。",
    ],
    "menuBarDisabled": ["The tray menu is hidden.", "菜单栏图标已隐藏。", "選單列圖示已隱藏。"],
    "menuBarItemLimit": ["Tray menu items", "托盘菜单条目数", "選單列選單項目數"],
    "menuBarItemLimitDescription": [
      "Show up to {0} clips, with pinned clips first. Enter 0 to show all (up to 1000).",
      "最多展示 {0} 个项目，固定项目优先。输入 0 展示全部（最多 1000 条）。", "最多顯示 {0} 個項目，固定項目優先。輸入 0 顯示全部（最多 1000 筆）。",
    ],
    "menuBarItemLimitDescription.zero": [
      "Pinned clips appear first. Enter 0 for all (up to 1000), or set a limit from 1 to 1000.",
      "固定项目优先。输入 0 展示全部（最多 1000 条），也可设置 1–1000。", "固定項目優先。輸入 0 顯示全部（最多 1000 筆），也可設定 1–1000。",
    ],
    "menuBarItemLimitDescription.one": [
      "Show up to 1 clip, with pinned clips first. Enter 0 to show all (up to 1000).",
      "最多展示 1 个项目，固定项目优先。输入 0 展示全部（最多 1000 条）。", "最多顯示 1 個項目，固定項目優先。輸入 0 顯示全部（最多 1000 筆）。",
    ],
    "menuBarItemLimitError": [
      "Enter 0 for all, or a whole number from 1 to 1000.", "请输入 0（全部）或 1–1000 的整数。",
      "請輸入 0（全部）或 1–1000 的整數。",
    ],
    "clipboardHistory": ["Clipboard history", "剪贴板历史", "剪貼簿歷史"],
    "clearHistoryDescription": [
      "There are {0} clipboard events on this Mac. Clearing history deletes only unpinned items.",
      "当前共 {0} 条记录。清空时只删除未固定的项目，固定项目会保留。", "目前共 {0} 筆記錄。只刪除未固定的項目，固定項目會保留。",
    ],
    "clearHistoryDescription.zero": [
      "There is no clipboard history to clear.", "目前没有可清空的剪贴板历史。", "目前沒有可清除的剪貼簿歷史。",
    ],
    "clearHistoryDescription.one": [
      "There are 1 clipboard event on this Mac. Clearing history deletes only unpinned items.",
      "当前共 1 条记录。清空时只删除未固定的项目，固定项目会保留。", "目前共 1 筆記錄。只刪除未固定的項目，固定項目會保留。",
    ],
    "clearHistoryConfirmationTitle": [
      "Clear unpinned clipboard history?", "清空未固定的剪贴板历史？", "清除未固定的剪貼簿歷史？",
    ],
    "clearHistoryConfirmationDescription": [
      "Of the {0} clipboard events on this Mac, only unpinned items will be permanently deleted. Pinned items will be kept.",
      "当前共 {0} 条记录。清空时只删除未固定的项目，固定项目会保留。", "目前共 {0} 筆記錄。只刪除未固定的項目，固定項目會保留。",
    ],
    "clearHistoryConfirmationDescription.one": [
      "Of the 1 clipboard event on this Mac, only unpinned items will be permanently deleted. Pinned items will be kept.",
      "当前共 1 条记录。清空时只删除未固定的项目，固定项目会保留。", "目前共 1 筆記錄。只刪除未固定的項目，固定項目會保留。",
    ],
    "clearingHistory": ["Clearing...", "正在清空...", "正在清除..."],
    "loadingMore": ["Loading more...", "正在加载...", "正在載入..."],
    "loadedHistoryCount": ["Showing {0} of {1} clips.", "已显示 {0}/{1} 条。", "已顯示 {0}/{1} 筆。"],
    "loadedHistoryCount.one": ["Showing {0} of 1 clip.", "已显示 {0}/1 条。", "已顯示 {0}/1 筆。"],
    "searchClipboardHistory": ["Search clipboard history", "搜索剪贴板历史", "搜尋剪貼簿歷史"],
    "clearSearch": ["Clear search", "清除搜索", "清除搜尋"],
    "searchMatch": ["Matching text", "匹配内容", "符合內容"],
    "loadedSearchCount": [
      "Showing {0} of {1} matching clips.", "已显示 {0}/{1} 条匹配记录。", "已顯示 {0}/{1} 筆符合記錄。",
    ],
    "noSearchResults": ["No matching clips", "没有匹配的记录", "沒有符合的記錄"],
    "noSearchResultsDescription": [
      "No clipboard history matches “{0}”.", "剪贴板历史中没有匹配“{0}”的内容。", "剪貼簿歷史中沒有符合「{0}」的內容。",
    ],
    "loadingHistory": ["Loading clipboard history...", "正在加载剪贴板历史...", "正在載入剪貼簿歷史..."],
    "loadingDetail": ["Loading full preview...", "正在加载完整预览...", "正在載入完整預覽..."],
    "detailUnavailable": ["The full preview is unavailable.", "无法显示完整预览。", "無法顯示完整預覽。"],
    "emptyHistoryCompact": [
      "Start copying text and it will appear here and in the menu bar menu.",
      "开始复制文字后，内容会显示在这里和菜单栏中。", "開始複製文字後，內容會顯示在這裡和選單列中。",
    ],
    "emptyHistoryAll": [
      "Start copying text or files and they will appear here and in the menu bar menu.",
      "开始复制文字或文件后，内容会显示在这里和菜单栏中。", "開始複製文字或檔案後，內容會顯示在這裡和選單列中。",
    ],
    "formattedPreviewTitle": ["Formatted clipboard preview", "格式化剪贴板内容预览", "格式化剪貼簿內容預覽"],
    "imageThumbnailAlt": ["{0} thumbnail", "{0}缩略图", "{0}縮圖"],
    "videoCoverAlt": ["{0} video cover", "{0}视频封面", "{0}影片封面"],
    "pngImage": ["PNG image", "PNG 图片", "PNG 圖片"],
    "textAndImage": ["Text + image", "文字和图片", "文字和圖片"],
    "eventTypes.text": ["Text", "文字", "文字"],
    "eventTypes.rtf": ["RTF", "RTF", "RTF"],
    "eventTypes.html": ["HTML", "HTML", "HTML"],
    "eventTypes.file": ["File", "文件", "檔案"],
    "eventTypes.folder": ["Folder", "文件夹", "資料夾"],
    "eventTypes.files": ["Files", "多个文件", "多個檔案"],
    "eventTypes.folders": ["Folders", "多个文件夹", "多個資料夾"],
    "eventTypes.files and folders": ["Files and folders", "文件和文件夹", "檔案和資料夾"],
    "eventTypes.video": ["Video", "视频", "影片"],
    "eventTypes.unsupported": ["Unsupported content", "不支持的内容", "不支援的內容"],
    "fileFallbackName": ["File {0}", "文件 {0}", "檔案 {0}"],
    "folderFallbackName": ["Folder {0}", "文件夹 {0}", "資料夾 {0}"],
    "moreItems": [" + {0} more", "，另有 {0} 项", "，另有 {0} 個項目"],
    "copiedToClipboard": ["Copied to clipboard", "已复制到剪贴板", "已複製到剪貼簿"],
    "restoreToClipboard": ["Restore to clipboard", "恢复到剪贴板", "還原至剪貼簿"],
    "restoringToClipboard": ["Restoring to clipboard...", "正在恢复到剪贴板...", "正在還原至剪貼簿..."],
    "deleteItem": ["Delete item", "删除项目", "刪除項目"],
    "deletingItem": ["Deleting item…", "正在删除项目…", "正在刪除項目…"],
    "deletePinnedConfirmationTitle": ["Delete this pinned item?", "删除此固定项目？", "刪除此固定項目？"],
    "deletePinnedConfirmationDescription": [
      "This item is pinned. Deleting it will permanently remove it from clipboard history.",
      "此项目已固定，删除后将从剪贴板历史中永久移除。", "此項目已固定，刪除後將從剪貼簿歷史中永久移除。",
    ],
    "deletePinnedCompactDescription": [
      "In compact mode, all items with the same text will also be deleted.",
      "精简模式下，所有具有相同文本的项目也会一并删除。", "精簡模式下，所有具有相同文字的項目也會一併刪除。",
    ],
    "pinItem": ["Pin item", "固定项目", "固定項目"],
    "recentHistory": ["Recent", "最近记录", "最近記錄"],
    "generalSettings": ["General", "通用", "一般"],
    "generalSettingsDescription": [
      "Language and startup preferences.", "管理语言与登录启动偏好。", "管理語言與登入啟動偏好。",
    ],
    "appearanceSettings": ["Appearance", "外观", "外觀"],
    "appearanceSettingsDescription": [
      "Choose how ClipEcho looks.", "选择 ClipEcho 的窗口外观。", "選擇 ClipEcho 的視窗外觀。",
    ],
    "themeDescription": [
      "Choose a light or dark appearance, or follow your Mac.", "选择浅色、深色，或跟随 Mac 的系统外观。",
      "選擇淺色、深色，或跟隨 Mac 的系統外觀。",
    ],
    "themeSystem": ["System", "跟随系统", "跟隨系統"],
    "themeLight": ["Light", "浅色", "淺色"],
    "themeDark": ["Dark", "深色", "深色"],
    "menuBarSettings": ["Menu Bar", "菜单栏", "選單列"],
    "menuBarSettingsDescription": [
      "Quick access to clipboard history from your menu bar.", "从菜单栏快速访问剪贴板历史。", "從選單列快速存取剪貼簿歷史。",
    ],
    "clipboardSettings": ["Clipboard", "剪贴板", "剪貼簿"],
    "clipboardSettingsDescription": [
      "Manage capture behavior and retained history.", "管理采集行为与历史保留规则。", "管理擷取行為與歷史保留規則。",
    ],
    "storageSettings": ["Storage", "存储", "儲存"],
    "storageDirectoryHelp": [
      "Choosing a new folder moves your history and settings there. If the move fails, your data and storage location stay unchanged.",
      "选择新目录后，会将历史记录和设置移动到该目录。移动失败时，数据和存储位置保持不变。", "選擇新目錄後，會將歷史記錄和設定移動到該目錄。移動失敗時，資料和儲存位置保持不變。",
    ],
    "changeStorageDirectory": ["Change…", "更改…", "更改…"],
    "movingStorage": ["Moving files…", "正在移动文件…", "正在移動檔案…"],
    "behaviorSettings": ["Capture & behavior", "采集与行为", "擷取與行為"],
    "unpinItem": ["Unpin item", "取消固定", "取消固定"],
    "pinUpdated": ["Pin status updated.", "固定状态已更新。", "固定狀態已更新。"],
    "pinRetentionHint": [
      "Pinned items are kept when clearing history or reaching storage limits. If pinned items alone exceed a limit, they are still kept. Unpinning applies the current limits immediately.",
      "固定项目不会被清空或自动淘汰；仅固定项目就超出数量或容量上限时，仍会保留。取消固定后立即应用当前上限。",
      "固定項目不會被清除或自動淘汰；僅固定項目就超出數量或容量上限時，仍會保留。取消固定後立即套用目前上限。",
    ],
    "clipboardItemCopied": ["Clipboard item copied.", "已复制到剪贴板。", "已複製到剪貼簿。"],
    "remoteClipboard": ["From another device", "来自其他设备", "來自其他裝置"],
    "previewTruncated": ["Summary shortened", "摘要已缩短", "摘要已縮短"],
    "dismiss": ["Dismiss", "关闭", "關閉"],
    "diagnosticDetails": ["Safe diagnostic details", "安全诊断信息", "安全診斷資訊"],
    "copyDiagnostic": ["Copy diagnostic", "复制诊断信息", "複製診斷資訊"],
    "diagnosticLoading": ["Loading safe diagnostic details...", "正在加载安全诊断信息...", "正在載入安全診斷資訊..."],
    "diagnosticUnavailable": [
      "Safe diagnostic details are unavailable.", "无法获取安全诊断信息。", "無法取得安全診斷資訊。",
    ],
    "diagnosticCopied": ["Diagnostic copied.", "诊断信息已复制。", "診斷資訊已複製。"],
    "diagnosticCopyFailed": ["The diagnostic could not be copied.", "无法复制诊断信息。", "無法複製診斷資訊。"],
    "reduceHistory": ["Reduce stored history?", "减少存储的历史记录？", "減少儲存的歷史記錄？"],
    "reduceHistoryDescription": [
      "Changing the storage limit from {0} to {1} will remove up to {2} clipboard events, starting with the oldest unpinned items. Pinned items will be kept.",
      "将存储上限从 {0} 改为 {1}，将从最旧的未固定项目开始，最多删除 {2} 条记录，固定项目会保留。",
      "將儲存上限從 {0} 改為 {1}，將從最舊的未固定項目開始，最多刪除 {2} 筆記錄，固定項目會保留。",
    ],
    "cannotUndo": ["This action cannot be undone.", "此操作无法撤销。", "此操作無法還原。"],
    "updating": ["Updating...", "正在更新...", "正在更新..."],
    "deleteAndUpdate": ["Delete and update", "删除并更新", "刪除並更新"],
    "error.startup": [
      "ClipEcho could not finish starting.", "ClipEcho 无法完成启动。", "ClipEcho 無法完成啟動。",
    ],
    "error.capture_clipboard": [
      "This clipboard item could not be saved.", "无法保存此剪贴板内容。", "無法儲存此剪貼簿內容。",
    ],
    "error.load_history": ["Clipboard history could not be loaded.", "无法加载剪贴板历史。", "無法載入剪貼簿歷史。"],
    "error.load_history_detail": [
      "This clipboard preview could not be loaded.", "无法加载此剪贴板预览。", "無法載入此剪貼簿預覽。",
    ],
    "error.restore_clipboard": [
      "This item could not be restored to the clipboard.", "无法将此项目恢复到剪贴板。", "無法將此項目還原至剪貼簿。",
    ],
    "error.delete_history": [
      "This clipboard item could not be deleted.", "无法删除此剪贴板项目。", "無法刪除此剪貼簿項目。",
    ],
    "error.pin_history": ["The pin status could not be updated.", "无法更新固定状态。", "無法更新固定狀態。"],
    "error.clear_history": ["Clipboard history could not be cleared.", "无法清空剪贴板历史。", "無法清除剪貼簿歷史。"],
    "error.load_settings": ["Settings could not be loaded.", "无法加载设置。", "無法載入設定。"],
    "error.update_settings": [
      "The setting could not be updated. Its saved value was restored.", "无法更新设置，已恢复保存的值。",
      "無法更新設定，已還原儲存的值。",
    ],
    "error.update_autostart": [
      "The login startup setting could not be updated.", "无法更新登录启动设置。", "無法更新登入啟動設定。",
    ],
    "error.move_storage": [
      "The files could not be moved. Your data and storage location are unchanged.",
      "文件移动失败，数据和存储位置仍保留在原目录。", "檔案移動失敗，資料和儲存位置仍保留在原目錄。",
    ],
    "error.write_history_mirror": [
      "The optional history export could not be updated.", "无法更新可选的历史记录导出。", "無法更新選用的歷史記錄匯出。",
    ],
    "error.storage_destination_exists": [
      "The files could not be moved because the destination contains a file with the same name. Choose another folder. Your data and storage location are unchanged.",
      "文件移动失败：目标目录中存在同名文件，请选择其他目录。数据和存储位置仍保留在原目录。", "檔案移動失敗：目標目錄中存在同名檔案，請選擇其他目錄。資料和儲存位置仍保留在原目錄。",
    ],
    "error.storage_permission_denied": [
      "The files could not be moved because access was denied. Choose a folder you can write to. Your data and storage location are unchanged.",
      "文件移动失败：没有访问权限，请选择可写入的目录。数据和存储位置仍保留在原目录。", "檔案移動失敗：沒有存取權限，請選擇可寫入的目錄。資料和儲存位置仍保留在原目錄。",
    ],
    "error.storage_invalid_directory": [
      "The files could not be moved to this folder. Choose another folder. Your data and storage location are unchanged.",
      "文件移动失败：无法使用此目录，请选择其他目录。数据和存储位置仍保留在原目录。", "檔案移動失敗：無法使用此目錄，請選擇其他目錄。資料和儲存位置仍保留在原目錄。",
    ],
    "settingsEllipsis": ["Settings…", "设置…", "設定…"],
    "recentClipboardItems": ["Recent clipboard items", "最近的剪贴板项目", "最近的剪貼簿項目"],
    "noClipboardItems": ["No clipboard items yet", "暂无剪贴板项目", "尚無剪貼簿項目"],
    "searchClipboard": ["Search clipboard…", "搜索剪贴板…", "搜尋剪貼簿…"],
    "openHistory": ["Open history", "打开历史记录", "開啟歷史記錄"],
    "openSettings": ["Open settings", "打开设置", "開啟設定"],
    "pinnedItems": ["Pinned", "已固定", "已固定"],
    "clearHistory": ["Clear unpinned history", "清空未固定的历史记录", "清除未固定的歷史記錄"],
    "quitClipecho": ["Quit ClipEcho", "退出 ClipEcho", "結束 ClipEcho"],
    "filesAndFolders": ["Files and folders", "文件和文件夹", "檔案和資料夾"],
    "view": ["View", "显示", "顯示"],
    "help": ["Help", "帮助", "輔助說明"],
    "aboutClipecho": ["About ClipEcho", "关于 ClipEcho", "關於 ClipEcho"],
    "hideClipecho": ["Hide ClipEcho", "隐藏 ClipEcho", "隱藏 ClipEcho"],
    "closeWindow": ["Close Window", "关闭窗口", "關閉視窗"],
    "redo": ["Redo", "重做", "重做"],
    "enterFullScreen": ["Enter Full Screen", "进入全屏幕", "進入全螢幕"],
    "zoom": ["Zoom", "缩放", "縮放"],
  ]
}

enum NativeFormatting {
  static func bytes(_ count: Int64, language: String = "system") -> String {
    let safe = max(0, count)
    if safe < 1_024 { return "\(safe) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var value = Double(safe) / 1_024
    var unit = 0
    while value >= 1_024 && unit < units.count - 1 {
      value /= 1_024
      unit += 1
    }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: L10n.resolve(language))
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = value >= 10 ? 1 : 2
    return (formatter.string(from: NSNumber(value: value)) ?? String(value)) + " " + units[unit]
  }

  static func timestamp(_ milliseconds: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.doesRelativeDateFormatting = true
    return formatter.string(from: date)
  }
}
