package com.yuchuan.app

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Parcelable
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.DocumentsContract
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * 雨传 YuChuan —— Android 原生能力桥（`yuchuan/platform`）。
 *
 * - MulticastLock / WifiLock：省电策略会丢组播包、切后台会断 Wi-Fi 多播（风险3）
 * - deviceName：Rust 侧在 Android 上取不到主机名，用 Build.MODEL
 * - filesDir：应用私有目录，device_id / 配对表 / 消息仓库落这里
 * - openFile / openUrl：用系统默认应用打开收到的文件（apk → 安装器）与链接
 * - 全面屏：edge-to-edge 且**不隐藏系统栏**（隐藏会让状态栏区域发黑、
 *   上滑才出现，观感就是「状态栏没适配」）；图标深浅跟随主题
 */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    /** 其他应用「分享」进来的内容：文字 + 文件 URI 列表。 */
    private var sharedText: String? = null
    private var sharedFiles: List<String> = emptyList()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupEdgeToEdge()
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // singleTop：已在前台时收到分享走这里，不重建 Activity
        handleShareIntent(intent)
    }

    /** 从 ACTION_SEND / SEND_MULTIPLE 里取出文字与文件路径。 */
    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return

        // 部分应用把 EXTRA_TEXT 存成 SpannableString：getStringExtra 返回 null
        // （或抛 ClassCastException）→ 文字分享变成空分享，表现「只把应用拉起来」。
        // getCharSequenceExtra 对 String / Spannable 都能取到。
        sharedText = try {
            intent.getStringExtra(Intent.EXTRA_TEXT)
                ?: intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        } catch (e: Exception) {
            null
        }

        val uris = mutableListOf<Uri>()
        @Suppress("UNCHECKED_CAST")
        (intent.getParcelableExtra<Parcelable>(Intent.EXTRA_STREAM) as? Uri)?.let { uris.add(it) }
        (intent.getParcelableArrayListExtra<Parcelable>(Intent.EXTRA_STREAM) as? List<Uri>?)
            ?.let { uris.addAll(it) }

        sharedFiles = uris.mapNotNull { uri ->
            try {
                copyToCache(uri)
            } catch (e: Exception) {
                null
            }
        }
    }

    /** 把分享进来的 content:// 拷到缓存目录，拿到可供传输的真实路径。 */
    private fun copyToCache(uri: Uri): String? {
        val name = queryDisplayName(uri) ?: "shared_${System.currentTimeMillis()}"
        val out = File(cacheDir, "share").apply { mkdirs() }
        val dest = File(out, name)
        contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(dest).use { output -> input.copyTo(output) }
        } ?: return null
        return dest.absolutePath
    }

    private fun queryDisplayName(uri: Uri): String? =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c ->
                if (c.moveToFirst()) {
                    val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (i >= 0) c.getString(i) else null
                } else null
            }

    /** 全面屏适配：内容延伸到系统栏后面，系统栏透明且保持可见。 */
    private fun setupEdgeToEdge() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        window.navigationBarColor = android.graphics.Color.TRANSPARENT
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        // 默认浅色背景 → 系统栏图标用深色；Dart 侧切主题时会再调一次
        controller.isAppearanceLightStatusBars = true
        controller.isAppearanceLightNavigationBars = true
    }

    /** 由 Dart 调用：切换状态栏/导航栏图标深浅（跟随明暗主题）。 */
    private fun setSystemBarsLight(light: Boolean) {
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.isAppearanceLightStatusBars = light
        controller.isAppearanceLightNavigationBars = light
    }

    /** 由 Dart 调用：显示/隐藏系统栏（true = 沉浸式隐藏）。 */
    private fun setSystemBarsHidden(hidden: Boolean) {
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        if (hidden) {
            controller.hide(WindowInsetsCompat.Type.systemBars())
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceName" -> result.success(deviceName())
                    "filesDir" -> result.success(filesDir.absolutePath)
                    "acquireMulticastLock" -> result.success(acquireMulticastLock())
                    "releaseMulticastLock" -> result.success(releaseMulticastLock())
                    "acquireWifiLock" -> result.success(acquireWifiLock())
                    "releaseWifiLock" -> result.success(releaseWifiLock())
                    "notificationsGranted" -> result.success(notificationsGranted())
                    "requestNotifications" -> {
                        requestNotifications()
                        result.success(true)
                    }
                    "setSystemBarsLight" -> {
                        setSystemBarsLight(call.arguments as? Boolean ?: false)
                        result.success(true)
                    }
                    "setSystemBarsHidden" -> {
                        setSystemBarsHidden(call.arguments as? Boolean ?: true)
                        result.success(true)
                    }
                    "takeShared" -> {
                        result.success(mapOf(
                            "text" to (sharedText ?: ""),
                            "files" to sharedFiles,
                        ))
                        // 只消费一次，避免旋转屏幕后重复上屏
                        sharedText = null
                        sharedFiles = emptyList()
                    }
                    "apkIcon" -> apkIconPath(call.arguments as? String ?: "", result)
                    "openFile" -> openFile(call.arguments as? String ?: "", result)
                    // 兼容入口：交给隐式 ACTION_VIEW（等价系统默认应用）。
                    // 现在「打开方式」走 listOpenWithApps + openFileWithPackage。
                    "openFileWithChooser" ->
                        openFile(call.arguments as? String ?: "", result)
                    // 自建「打开方式」选择窗口：先列出能打开该文件的应用，
                    // 由 Dart 侧弹「仅一次 / 始终」，再按选择打开（始终会记忆）。
                    "listOpenWithApps" ->
                        listOpenWithApps(call.arguments as? String ?: "", result)
                    "openFileWithPackage" -> {
                        val args = call.arguments as? Map<*, *>
                        openFileWithPackage(
                            args?.get("path") as? String ?: "",
                            args?.get("package") as? String ?: "",
                            result,
                        )
                    }
                    "openUrl" -> openUrl(call.arguments as? String ?: "", result)
                    "revealFolder" -> revealFolder(call.arguments as? String ?: "", result)
                    "takeTreePermission" ->
                        takeTreePermission(call.arguments as? String ?: "", result)
                    "archiveToTree" -> {
                        @Suppress("UNCHECKED_CAST")
                        archiveToTree(call.arguments as? Map<String, Any?> ?: emptyMap(), result)
                    }
                    "persistTreeForPath" ->
                        persistTreeForPath(call.arguments as? String ?: "", result)
                    "archiveToMediaStore" -> {
                        @Suppress("UNCHECKED_CAST")
                        archiveToMediaStore(
                            call.arguments as? Map<String, Any?> ?: emptyMap(), result)
                    }
                    "publicDownloadPath" -> result.success(publicDownloadPath())
                    "revealPublicDownloadDir" -> revealPublicDownloadDir(result)

                    "startKeepAlive" -> {
                        val args = call.arguments as? Map<*, *>
                        val title = args?.get("title") as? String ?: "雨传正在后台传输"
                        val text = args?.get("text") as? String ?: "保持连接，避免传输中断"
                        TransferService.start(this, title, text)
                        result.success(true)
                    }
                    "stopKeepAlive" -> {
                        TransferService.stop(this)
                        result.success(true)
                    }
                    "isKeepAliveRunning" -> result.success(TransferService.isRunning())
                    else -> result.notImplemented()
                }
            }
    }

    private fun deviceName(): String {
        val model = Build.MODEL?.trim().orEmpty()
        return if (model.isEmpty()) "雨传设备" else model
    }

    private fun acquireMulticastLock(): Boolean {
        if (multicastLock?.isHeld == true) return true
        return try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: return false
            val lock = wifi.createMulticastLock("yuchuan-discovery")
            lock.setReferenceCounted(true)
            lock.acquire()
            multicastLock = lock
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun releaseMulticastLock(): Boolean {
        val lock = multicastLock ?: return false
        return try {
            if (lock.isHeld) lock.release()
            multicastLock = null
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 高性能 Wi-Fi 锁：切后台时系统不降级 Wi-Fi，聊天/传输不断连。 */
    private fun acquireWifiLock(): Boolean {
        if (wifiLock?.isHeld == true) return true
        return try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: return false
            @Suppress("DEPRECATION")
            val lock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "yuchuan-wifi")
            lock.setReferenceCounted(false)
            lock.acquire()
            wifiLock = lock
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun releaseWifiLock(): Boolean {
        val lock = wifiLock ?: return false
        return try {
            if (lock.isHeld) lock.release()
            wifiLock = null
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 用系统默认应用打开文件：apk → 安装器；其余按扩展名猜 MIME。
     * 通过 FileProvider 暴露 content:// URI（跨应用读权限只授给目标应用）。
     */
    private fun openFile(path: String, result: MethodChannel.Result) {
        val file = File(path)
        if (!file.exists()) {
            result.error("ENOENT", "文件不存在: $path", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$authority.fileprovider", file)
            val mime = mimeOf(file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (file.name.lowercase().endsWith(".apk")) {
                // 安装未知来源需要用户授权；系统安装器会自己弹引导
                intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            if (intent.resolveActivity(packageManager) == null) {
                result.error("NO_HANDLER", "没有可以打开 $mime 的应用", null)
                return
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message, null)
        }
    }

    /** 按扩展名推 MIME（打开文件 / 打开方式共用）。 */
    private fun mimeOf(file: File): String {
        val lower = file.name.lowercase()
        return when {
            lower.endsWith(".apk") -> "application/vnd.android.package-archive"
            lower.endsWith(".png") -> "image/png"
            lower.endsWith(".jpg") || lower.endsWith(".jpeg") -> "image/jpeg"
            lower.endsWith(".gif") -> "image/gif"
            lower.endsWith(".webp") -> "image/webp"
            lower.endsWith(".mp4") -> "video/mp4"
            lower.endsWith(".mkv") -> "video/x-matroska"
            lower.endsWith(".mp3") -> "audio/mpeg"
            lower.endsWith(".pdf") -> "application/pdf"
            lower.endsWith(".txt") || lower.endsWith(".md") -> "text/plain"
            else -> MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(file.extension.lowercase())
                ?: "application/octet-stream"
        }
    }

    /**
     * 自建「打开方式」：列出所有能打开该文件的应用，交给 Dart 侧弹选择窗口。
     *
     * 不能再依赖系统 ResolverActivity 的「仅一次 / 始终」：Android 11+
     * 对隐式 ACTION_VIEW 不再提供那组按钮（用户反馈「一直没有实现、毫无变化」）。
     * 所以应用自己查 `queryIntentActivities` 列候选，自己弹窗、自己记「始终」。
     *
     * 返回 List<Map>：package / label / isDefault。
     */
    private fun listOpenWithApps(path: String, result: MethodChannel.Result) {
        val file = File(path)
        if (!file.exists()) {
            result.error("ENOENT", "文件不存在: $path", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$authority.fileprovider", file)
            val mime = mimeOf(file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            // MATCH_DEFAULT_ONLY 会漏掉「只在 chooser 里出现」的应用
            // （很多修图/阅读类 app 就是这样）。列候选必须放宽到全部匹配项，
            // 否则自建窗口里应用少一大截（用户反馈：选择框里没几个应用）。
            val flags = 0
            val resolved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.queryIntentActivities(
                    intent,
                    PackageManager.ResolveInfoFlags.of(flags.toLong()),
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.queryIntentActivities(intent, flags)
            }
            val defaultPkg = intent.resolveActivity(packageManager)?.packageName
            val out = ArrayList<Map<String, Any?>>()
            val seen = HashSet<String>()
            for (ri in resolved) {
                val pkg = ri.activityInfo?.packageName ?: continue
                // 过滤自己，避免「用雨传打开雨传」
                if (pkg == packageName) continue
                if (!seen.add(pkg)) continue
                out.add(
                    mapOf(
                        "package" to pkg,
                        "label" to ri.loadLabel(packageManager).toString(),
                        "isDefault" to (pkg == defaultPkg),
                        // 应用图标（PNG 字节）→ Dart 侧 Image.memory 显示。
                        // 取不到就回 null，Dart 退回通用类型图标。
                        "icon" to loadIconPng(ri),
                    )
                )
            }
            // 默认应用排最前
            out.sortByDescending { it["isDefault"] == true }
            result.success(out)
        } catch (e: Exception) {
            result.error("LIST_FAILED", e.message, null)
        }
    }

    /**
     * 把 ResolveInfo 的应用图标编码成 PNG 字节（自建「打开方式」窗口要显示图标）。
     *
     * 部分应用给的是 AdaptiveIconDrawable，直接 draw 到固定 96x96 画布上最稳；
     * 任何一步失败都返回 null，让 Dart 侧退回通用图标，绝不因此中断列表。
     */
    private fun loadIconPng(ri: android.content.pm.ResolveInfo): ByteArray? {
        return try {
            val drawable = ri.loadIcon(packageManager) ?: return null
            val size = 96
            val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            val bos = java.io.ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 100, bos)
            bmp.recycle()
            bos.toByteArray()
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * 用**指定包名**的应用打开文件（配合自建选择窗口的「始终」记忆）。
     * package 为空时退化成隐式 ACTION_VIEW（等价系统默认应用）。
     */
    private fun openFileWithPackage(
        path: String,
        pkg: String,
        result: MethodChannel.Result,
    ) {
        val file = File(path)
        if (!file.exists()) {
            result.error("ENOENT", "文件不存在: $path", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$authority.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeOf(file))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (pkg.isNotEmpty()) {
                // 指定包名 + 组件，跳过系统选择器，直接进用户记住的那个应用
                val resolved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    packageManager.queryIntentActivities(
                        intent,
                        PackageManager.ResolveInfoFlags.of(
                            PackageManager.MATCH_DEFAULT_ONLY.toLong()
                        ),
                    )
                } else {
                    @Suppress("DEPRECATION")
                    packageManager.queryIntentActivities(
                        intent,
                        PackageManager.MATCH_DEFAULT_ONLY,
                    )
                }
                val hit = resolved.firstOrNull {
                    it.activityInfo?.packageName == pkg
                }
                if (hit != null) {
                    intent.setClassName(pkg, hit.activityInfo.name)
                } else {
                    // 记忆的应用已被卸载/不再支持该类型 → 让调用方重新选
                    result.error("STALE_PACKAGE", "已记住的应用不可用: $pkg", null)
                    return
                }
            }
            if (intent.resolveActivity(packageManager) == null) {
                result.error("NO_HANDLER", "没有可以打开该文件的应用", null)
                return
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message, null)
        }
    }
    /**
     * 取 APK 的安装图标，写到缓存并返回图片路径（供文件列表显示真实图标）。
     *
     * 图标来源是 PackageManager，drawable → bitmap → PNG 落盘。
     * 非 .apk 文件返回 null，调用方退回类型默认图标。
     */
    private fun apkIconPath(path: String, result: MethodChannel.Result) {
        val file = File(path)
        if (!file.exists() || !file.name.lowercase().endsWith(".apk")) {
            result.success(null)
            return
        }
        try {
            val pm = packageManager
            val info = pm.getPackageArchiveInfo(path, 0) ?: run {
                result.success(null)
                return
            }
            // getApplicationInfo 带上源路径，才能解析出归档里的资源
            val appInfo = info.applicationInfo ?: run {
                result.success(null)
                return
            }
            appInfo.sourceDir = path
            appInfo.publicSourceDir = path
            val icon = pm.getApplicationIcon(appInfo)
            val bmp = drawableToBitmap(icon) ?: run {
                result.success(null)
                return
            }
            val out = File(cacheDir, "apkicons").apply { mkdirs() }
            val dest = File(out, "${info.packageName}.png")
            FileOutputStream(dest).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
            result.success(dest.absolutePath)
        } catch (e: Exception) {
            result.success(null)
        }
    }

    /** Drawable/Icon → Bitmap（矢量图也能拿到位图）。 */
    private fun drawableToBitmap(d: Drawable): Bitmap? {
        val w = (d.intrinsicWidth).takeIf { it > 0 } ?: 96
        val h = (d.intrinsicHeight).takeIf { it > 0 } ?: 96
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        d.setBounds(0, 0, w, h)
        d.draw(canvas)
        return bmp
    }
    /**
     * 「打开所在文件夹」：把**目录**交给系统文件管理器浏览。
     *
     * 入参既可能是文件/目录的真实路径，也可能是 SAF 的 `content://` 树 URI。
     * 返回：null=已打开；`"APP_INTERNAL"`=找不到可浏览的目录（如目录在应用
     * 私有区，外部文件管理器进不去），由 Dart 转成中文失败提示；
     * 其余走 `result.error`。
     */
    private fun revealFolder(arg: String, result: MethodChannel.Result) {
        try {
            if (arg.startsWith("content://")) {
                val uri = Uri.parse(arg)
                val docUri = try {
                    DocumentsContract.buildDocumentUriUsingTree(
                        uri, DocumentsContract.getTreeDocumentId(uri))
                } catch (e: Exception) {
                    uri
                }
                if (browseAt(docUri)) result.success(null)
                else result.error("NO_HANDLER", "没有可以浏览该目录的应用", null)
                return
            }
            val f = File(arg)
            val dir = if (f.isDirectory) f else f.parentFile
            if (dir == null) {
                result.error("ENOENT", "目录不存在: $arg", null)
                return
            }
            val path = dir.absolutePath.trimEnd('/')
            val docId = externalDocId(path)
            // 应用私有区（/data/…、Android/data、Android/obb）外部进不去
            if (isPrivatePath(path) || docId == null) {
                result.success(APP_INTERNAL)
                return
            }
            // 若我们持有覆盖该目录的持久化 SAF 授权，改用树内 document URI：
            // browseAt 会随 Intent 转授读权限，文件管理器才打得开。
            val covering = persistedTreeCovering(docId)
            val docUri = if (covering != null) {
                DocumentsContract.buildDocumentUriUsingTree(covering, docId)
            } else {
                Uri.parse(
                    "content://$EXTERNAL_AUTHORITY/document/" +
                        Uri.encode(docId)
                )
            }
            if (browseAt(docUri)) result.success(null)
            else result.error("NO_HANDLER", "没有可以打开该目录的应用", null)
        } catch (e: Exception) {
            result.error("REVEAL_FAILED", e.message, null)
        }
    }

    /** 依次尝试：文件管理器直接浏览该目录 → 系统选择器定位到该目录。 */
    private fun browseAt(uri: Uri): Boolean {
        listOf("vnd.android.document/directory", "resource/folder").forEach { mime ->
            val view = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                // 带读授权：content:// URI 时接收方文件管理器
                // 才能借我们的 SAF 授权浏览（无授权时该 flag 无副作用）
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            if (view.resolveActivity(packageManager) != null) {
                try {
                    startActivity(view)
                    return true
                } catch (e: Exception) {
                    // 继续尝试下一种方式
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val tree = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                // EXTRA_INITIAL_URI：让选择器直接停在目标目录
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, uri)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (tree.resolveActivity(packageManager) != null) {
                try {
                    startActivity(tree)
                    return true
                } catch (e: Exception) {
                }
            }
        }
        return false
    }

    /** 是否落在外部文件管理器进不去的私有区。 */
    private fun isPrivatePath(path: String): Boolean {
        val p = path.trimEnd('/')
        if (p == "/data" || p.startsWith("/data/")) return true
        if (p.contains("/Android/data/") || p.contains("/Android/obb/")) return true
        return !(p.startsWith("/storage/") || p.startsWith("/sdcard/") ||
            p.startsWith("/mnt/media_rw/"))
    }

    /**
     * 真实路径 → externalstorage 的 document id
     * （`/storage/emulated/0/Download` → `primary:Download`，
     *  `/storage/XXXX-XXXX/foo` → `XXXX-XXXX:foo`）；不是外部存储返回 null。
     */
    private fun externalDocId(path: String): String? {
        val p = path.trimEnd('/')
        return when {
            p.startsWith("/storage/emulated/") -> {
                val rest = p.removePrefix("/storage/emulated/")
                val i = rest.indexOf('/')
                if (i < 0) "primary:" else "primary:" + rest.substring(i + 1)
            }
            p.startsWith("/sdcard/") -> "primary:" + p.removePrefix("/sdcard/")
            p.startsWith("/mnt/media_rw/") -> {
                val rest = p.removePrefix("/mnt/media_rw/")
                val i = rest.indexOf('/')
                if (i > 0) rest.substring(0, i) + ":" + rest.substring(i + 1) else null
            }
            p.startsWith("/storage/") -> {
                val rest = p.removePrefix("/storage/")
                val i = rest.indexOf('/')
                if (i > 0) {
                    val vol = rest.substring(0, i)
                    if (vol == "emulated" || vol == "self") null
                    else vol + ":" + rest.substring(i + 1)
                } else null
            }
            else -> null
        }
    }

    /**
     * 持久化 SAF 目录树授权。选择目录后**马上**调一次 —— file_picker 不做这件事，
     * 临时授权在进程结束/重启后就没了，之后收到的文件写不进去。
     */
    private fun takeTreePermission(treeUri: String, result: MethodChannel.Result) {
        try {
            contentResolver.takePersistableUriPermission(
                Uri.parse(treeUri),
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            result.success(true)
        } catch (e: Exception) {
            result.error("TAKE_FAILED", e.message, null)
        }
    }

    /**
     * file_picker 在安卓选目录返回的是解析后的**真实路径**（不是 content://），
     * 不带任何可写授权 → dart:io 直接写共享存储必然被拒。
     * 这里用真实路径重建 tree URI，把选择器刚给的瞬时授权转成持久授权，
     * 返回 `content://…/tree/…`（调用方把它存为接收目录）。
     * 瞬时授权已过期（比如重启后没重新选过目录）→ TAKE_FAILED。
     */
    private fun persistTreeForPath(path: String, result: MethodChannel.Result) {
        val docId = externalDocId(path)
        if (docId == null) {
            result.error("NO_EXTERNAL", "该目录不在外部存储: $path", null)
            return
        }
        val treeUri = Uri.parse("content://$EXTERNAL_AUTHORITY/tree/" + Uri.encode(docId))
        try {
            contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            result.success(treeUri.toString())
        } catch (e: Exception) {
            result.error("TAKE_FAILED", e.message, null)
        }
    }

    /** 找一个我们已持久化授权、且覆盖 [docId] 的 SAF 树；没有返回 null。 */
    private fun persistedTreeCovering(docId: String): Uri? {
        try {
            for (p in contentResolver.persistedUriPermissions) {
                if (!p.isReadPermission) continue
                if (p.uri.authority != EXTERNAL_AUTHORITY) continue
                val t = DocumentsContract.getTreeDocumentId(p.uri)
                if (docId == t || docId.startsWith("$t/")) return p.uri
            }
        } catch (_: Exception) {
        }
        return null
    }

    /**
     * 把收到的文件复制进用户选择的 SAF 接收目录（`rel` 是 `»` 拆出的子目录链）。
     * IO 放后台线程，避免大文件拷贝卡住主线程。
     */
    private fun archiveToTree(args: Map<String, Any?>, result: MethodChannel.Result) {
        val src = args["src"] as? String ?: ""
        val tree = args["tree"] as? String ?: ""
        val rel = args["rel"] as? String ?: ""
        val name = args["name"] as? String ?: ""
        Thread {
            try {
                val srcFile = File(src)
                if (!srcFile.exists()) {
                    result.error("ENOENT", "源文件不存在: $src", null)
                    return@Thread
                }
                // tree 既可能是 content:// 树，也可能是 file_picker 选目录
                // 返回的**真实路径**（安卓上始终是后者）→ 用真实路径重建树 URI。
                val treeUri = if (tree.startsWith("content://")) {
                    Uri.parse(tree)
                } else {
                    val realDocId = externalDocId(tree)
                    if (realDocId == null) {
                        result.error("NO_EXTERNAL", "该目录不在外部存储: $tree", null)
                        return@Thread
                    }
                    Uri.parse("content://$EXTERNAL_AUTHORITY/tree/" + Uri.encode(realDocId))
                }
                try {
                    contentResolver.takePersistableUriPermission(
                        treeUri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                } catch (e: Exception) {
                    result.error(
                        "TAKE_FAILED",
                        "接收目录授权不可用（请在设置里重新选择该目录）：${e.message}",
                        null,
                    )
                    return@Thread
                }
                var parent = DocumentsContract.buildDocumentUriUsingTree(
                    treeUri, DocumentsContract.getTreeDocumentId(treeUri))
                for (seg in rel.split('/').filter { it.isNotBlank() }) {
                    val sub = childDir(treeUri, parent, seg)
                    if (sub == null) {
                        result.error("MKDIR_FAILED", "无法创建子目录 $seg", null)
                        return@Thread
                    }
                    parent = sub
                }
                val display = uniqueName(name, childNames(parent))
                val doc = DocumentsContract.createDocument(
                    contentResolver, parent, mimeOf(File(display)), display)
                if (doc == null) {
                    result.error("CREATE_FAILED", "无法在接收目录创建文件 $display", null)
                    return@Thread
                }
                val out = contentResolver.openOutputStream(doc)
                if (out == null) {
                    result.error("OPEN_FAILED", "无法写入接收目录: $display", null)
                    return@Thread
                }
                srcFile.inputStream().use { input -> out.use { o -> input.copyTo(o) } }
                result.success(null)
            } catch (e: Exception) {
                result.error("ARCHIVE_FAILED", e.message, null)
            }
        }.start()
    }

    /** 在树里找（没有就建）子目录，返回其 document URI。 */
    private fun childDir(tree: Uri, parent: Uri, name: String): Uri? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            parent, DocumentsContract.getDocumentId(parent))
        contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(1) == name &&
                    c.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR
                ) {
                    return DocumentsContract.buildDocumentUriUsingTree(tree, c.getString(0))
                }
            }
        }
        // Android SDK 没有 DocumentsContract.createDirectory，用 createDocument 建目录。
        return try {
            DocumentsContract.createDocument(
                contentResolver, parent,
                DocumentsContract.Document.MIME_TYPE_DIR, name,
            )
        } catch (_: Exception) {
            null
        }
    }

    /** 父目录下已有的显示名（用于重名自动编号）。 */
    private fun childNames(parent: Uri): Set<String> {
        val used = mutableSetOf<String>()
        try {
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(
                parent, DocumentsContract.getDocumentId(parent))
            contentResolver
                .query(children, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c -> while (c.moveToNext()) c.getString(0)?.let { used.add(it) } }
        } catch (_: Exception) {
        }
        return used
    }

    /** `report.pdf` 撞名 → `report (1).pdf`…（与 Dart 侧默认目录的规则一致）。 */
    private fun uniqueName(name: String, used: Set<String>): String {
        if (!used.contains(name)) return name
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        for (i in 1..999) {
            val candidate = "$base ($i)$ext"
            if (!used.contains(candidate)) return candidate
        }
        return "$base (${System.currentTimeMillis()})$ext"
    }

    // ------------------------------------------------------------------
    // Android 10+ 公共「下载」目录（MediaStore）
    //
    // 应用零存储权限（targetSdk 36，见 docs/permissions.md），共享可见的
    // Download/雨传 只能走 MediaStore：它对应用私有区之外的下载是官方通道，
    // 且 IS_PENDING 能保证「先写完再对外可见」，不会出现半截文件被其它
    // 应用（相册/文件管理器）看到。
    // ------------------------------------------------------------------

    /** 公共下载目录里的应用子目录名（与用户要求的「Download/雨传」一致）。 */
    private val MEDIA_SUBDIR = "雨传"

    /**
     * 把文件写进公共 Download/雨传（Android 10+ 走 MediaStore）。
     *
     * 入参：src 源文件路径、rel 子目录链（空串=根）、name 文件名。
     * 返回 null=成功；否则是错误文案。IO 放后台线程（大文件拷贝不能卡主线程）。
     */
    private fun archiveToMediaStore(args: Map<String, Any?>, result: MethodChannel.Result) {
        val src = args["src"] as? String ?: ""
        val rel = args["rel"] as? String ?: ""
        val name = args["name"] as? String ?: ""
        Thread {
            try {
                val srcFile = File(src)
                if (!srcFile.exists()) {
                    result.error("ENOENT", "源文件不存在: $src", null)
                    return@Thread
                }
                if (name.isBlank()) {
                    result.error("BAD_NAME", "文件名为空", null)
                    return@Thread
                }
                // Android 9 及以下写公共下载目录需要 WRITE_EXTERNAL_STORAGE，
                // 而本应用零存储权限（docs/permissions.md）——明确报错，让上层的
                // 横幅提示用户去设置里自定义接收目录，而不是静默丢文件。
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    result.error(
                        "UNSUPPORTED",
                        "当前系统版本需要存储权限才能写入公共下载目录，" +
                            "请在设置里自定义接收目录",
                        null,
                    )
                    return@Thread
                }
                val collection =
                    MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                // 子目录链（文件夹传输的 » 已被 Dart 拆成 rel）
                val segments = (listOf(MEDIA_SUBDIR) +
                    rel.split('/').filter { it.isNotBlank() })
                val relative = segments.joinToString("/")
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeOf(File(name)))
                    put(MediaStore.MediaColumns.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS + "/" + relative)
                    // IS_PENDING：先占用再写，写完才对外可见 —— 否则文件管理器
                    // /相册可能读到半截文件
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(collection, values)
                if (uri == null) {
                    result.error("CREATE_FAILED", "无法在 Download/$MEDIA_SUBDIR 创建文件", null)
                    return@Thread
                }
                try {
                    val out = contentResolver.openOutputStream(uri)
                    if (out == null) {
                        result.error("OPEN_FAILED", "无法写入 Download/$MEDIA_SUBDIR", null)
                        return@Thread
                    }
                    srcFile.inputStream().use { input -> out.use { o -> input.copyTo(o) } }
                } catch (e: Exception) {
                    // 写失败要清掉占位记录，否则下载目录里留下 0 字节的幽灵文件
                    runCatching { contentResolver.delete(uri, null, null) }
                    result.error("WRITE_FAILED", e.message, null)
                    return@Thread
                }
                // 写完了才解除 pending，文件从此对其它应用可见
                val done = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }
                contentResolver.update(uri, done, null, null)
                result.success(uri.toString())
            } catch (e: Exception) {
                result.error("ARCHIVE_FAILED", e.message, null)
            }
        }.start()
    }

    /**
     * 公共下载目录里的收件目录真实路径（设置页展示用）。
     *
     * 应用对公共下载目录没有 dart:io 权限，但「路径字符串」本身可以取得，
     * 用于让 UI 显示与用户实际能在文件管理器里看到的路径一致。
     */
    private fun publicDownloadPath(): String =
        "${Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS)}/$MEDIA_SUBDIR"

    /**
     * 打开公共 `Download/雨传`。
     *
     * 该目录不在应用私有区，且没有 dart:io 权限 → 只能构造 document URI
     * 交给系统文件管理器浏览。目录还不存在（尚未收到过文件）时退到
     * Download 本身，至少让用户看到文件会落在哪。
     */
    private fun revealPublicDownloadDir(result: MethodChannel.Result) {
        try {
            val path = publicDownloadPath()
            val docId = externalDocId(path)
            if (docId == null) {
                result.success(APP_INTERNAL)
                return
            }
            val docUri = Uri.parse(
                "content://$EXTERNAL_AUTHORITY/document/" + Uri.encode(docId))
            if (browseAt(docUri)) {
                result.success(null)
                return
            }
            val parentDocId = externalDocId(File(path).parent ?: "")
            if (parentDocId != null) {
                val parentUri = Uri.parse(
                    "content://$EXTERNAL_AUTHORITY/document/" + Uri.encode(parentDocId))
                if (browseAt(parentUri)) {
                    result.success(null)
                    return
                }
            }
            result.error("NO_HANDLER", "没有可以浏览该目录的应用", null)
        } catch (e: Exception) {
            result.error("REVEAL_FAILED", e.message, null)
        }
    }

    /** 浏览器打开链接。 */
    private fun openUrl(url: String, result: MethodChannel.Result) {
        try {
            val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (intent.resolveActivity(packageManager) == null) {
                result.error("NO_HANDLER", "没有可以打开链接的应用", null)
                return
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message, null)
        }
    }

    /**
     * 通知权限引导：先解释用途，用户点「允许通知」后才弹系统框（PLAN §3.2）。
     * Android 13 以下无需该权限，直接视为已授权。
     */
    private fun notificationsGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (notificationsGranted()) return
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATIONS,
        )
    }

    override fun onDestroy() {
        // Activity 的锁与服务里的锁是**不同对象**（tag 不同），「移交」不存在。
        // 无论服务在不在跑，Activity 自己持有的锁都必须释放，否则配置变更/
        // 系统回收 Activity 后锁永久被 Activity 对象持有（耗电，审查 major5）。
        releaseMulticastLock()
        releaseWifiLock()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "yuchuan/platform"
        private const val authority = "com.yuchuan.app"
        private const val REQUEST_NOTIFICATIONS = 1001

        /** [revealFolder] 的返回值：目录在应用私有区，外部打不开。 */
        private const val APP_INTERNAL = "APP_INTERNAL"

        /** 系统「文件」documents provider（外部存储的 document URI）。 */
        private const val EXTERNAL_AUTHORITY = "com.android.externalstorage.documents"
    }
}
