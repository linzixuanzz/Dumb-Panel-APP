package com.daidai.panel

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

private const val LOG_TAG = "AppInstall"

/**
 * 内置安装失败的原因。
 *
 * code 与 Dart 侧 `app_update_service.dart` 的 `_installErrorText` 一一对应，
 * 任何一侧新增 code 都要同步；漏了只会退化成显示英文原文，不会崩（issue #11 / v1.3.7）。
 */
class InstallException(val code: String, message: String) : Exception(message)

class MainActivity : FlutterFragmentActivity() {

    private val CHANNEL = "com.daidai.panel/app_install"
    private val trustedDownloadHosts = setOf(
        "github.com",
        "objects.githubusercontent.com",
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        val sourceHost = call.argument<String>("sourceHost")
                        if (path == null) {
                            result.error("INVALID_PATH", "APK path is null", null)
                        } else {
                            // result 不在这里结掉：PackageInstaller 是异步的，真正的成败
                            // 由 InstallResultReceiver 收到系统广播后回传（issue #11 / v1.3.7）
                            InstallResultReceiver.begin(result)
                            // 整段挪到子线程：verifyArchivePackage 要解析整包并验签，
                            // 再加上把几十 MB 的 APK 字节拷进会话，跑在平台主线程必 ANR
                            Thread({
                                try {
                                    installApk(path, sourceHost)
                                } catch (e: Exception) {
                                    Log.e(LOG_TAG, "installApk failed", e)
                                    InstallResultReceiver.finish(
                                        (e as? InstallException)?.code ?: "SESSION_FAILED",
                                        e.message,
                                    )
                                }
                            }, "daidai-app-install").start()
                        }
                    }

                    "openUnknownSourceSettings" -> {
                        try {
                            // API 26 才有「按应用授权安装未知应用」这个页面；
                            // 更老的系统是一个全局开关，只能把用户送到安全设置里
                            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName"),
                                )
                            } else {
                                Intent(Settings.ACTION_SECURITY_SETTINGS)
                            }
                            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(null)
                        } catch (e: Exception) {
                            Log.e(LOG_TAG, "open unknown source settings failed", e)
                            result.error("NO_SETTINGS_PAGE", e.message, null)
                        }
                    }

                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        // 只放行 https：这条通道只服务关于页那几个写死的外链，
                        // 放开 scheme 等于让 Dart 侧任意字符串都能拉起任意组件
                        // （intent:// / file:// 都能塞进来），属白送的注入面（issue #12 / v1.3.7）
                        if (url == null || !url.startsWith("https://")) {
                            result.error("INVALID_URL", "only https allowed", null)
                        } else {
                            try {
                                // startActivity 不受 Android 11 的包可见性过滤（受限的是
                                // queryIntentActivities / resolveActivity 这类**查询** API），
                                // 所以这条路连 <queries> 声明都不用加。
                                // 设备上没有浏览器时抛 ActivityNotFoundException，
                                // 由下面的 catch 回成错误，Dart 侧退回「复制链接」。
                                startActivity(
                                    Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                                result.success(null)
                            } catch (e: Exception) {
                                Log.e(LOG_TAG, "openUrl failed: $url", e)
                                result.error("NO_BROWSER", e.message, null)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(filePath: String, sourceHost: String?) {
        val normalizedHost = sourceHost?.lowercase()
        if (normalizedHost.isNullOrBlank() || !isTrustedHost(normalizedHost)) {
            throw InstallException("UNTRUSTED_SOURCE", "Untrusted update source")
        }

        val file = File(filePath)
        if (!file.exists() || !file.isFile) {
            throw InstallException("FILE_MISSING", "APK file does not exist")
        }
        if (!isFileInsideCache(file)) {
            throw InstallException("PATH_NOT_ALLOWED", "APK file path is not allowed")
        }
        if (!verifyArchivePackage(file)) {
            throw InstallException("VERIFY_FAILED", "APK verification failed")
        }

        // PackageInstaller 同样受「安装未知应用」开关约束，没授权时 commit 会直接失败。
        // 提前把用户送到授权页，代价是本次安装就此中断，用户回来要再点一次（issue #11 / v1.3.7）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            throw InstallException("NEED_UNKNOWN_SOURCE", "需要先允许本应用安装未知应用")
        }

        // 不再走 Intent(ACTION_VIEW) 拉系统安装器：targetSdk 36 ≥ 30 会被包可见性过滤，
        // 系统安装器对本 APP 不可见，Intent 解析出空集直接抛 ActivityNotFoundException —— 这正是
        // issue #11 的报错。PackageInstaller 由本进程把 APK 字节写进会话，全程不做 Intent 解析，
        // 对「包可见性 / ROM 纯净模式 / 第三方安装器缺失」三种成因都免疫。
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL
        )
        params.setSize(file.length())

        var sessionId = -1
        try {
            sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                session.openWrite("base.apk", 0, file.length()).use { out ->
                    file.inputStream().use { input -> input.copyTo(out) }
                    session.fsync(out)
                }

                // FLAG_MUTABLE 是硬要求：系统要往这个 PendingIntent 里回填安装状态，
                // API 31+ 不带它会直接拒绝。Intent 指明了组件，属于显式 Intent，
                // 因此不会踩 Android 14「可变 PendingIntent 不能配隐式 Intent」那条限制。
                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
                val callback = PendingIntent.getBroadcast(
                    this,
                    sessionId,
                    Intent(this, InstallResultReceiver::class.java),
                    flags,
                )
                session.commit(callback.intentSender)
            }
        } catch (e: Exception) {
            // 写到一半失败必须把会话丢掉，否则残留会话会一直占着安装暂存空间
            if (sessionId != -1) {
                try {
                    installer.abandonSession(sessionId)
                } catch (ignored: Exception) {
                    Log.e(LOG_TAG, "abandon session failed", ignored)
                }
            }
            throw InstallException("SESSION_FAILED", e.message ?: "创建安装会话失败")
        }
    }

    private fun isTrustedHost(host: String): Boolean {
        return host in trustedDownloadHosts || host.endsWith(".githubusercontent.com")
    }

    private fun isFileInsideCache(file: File): Boolean {
        val cacheRoot = cacheDir.canonicalFile
        val targetFile = file.canonicalFile
        return targetFile.path.startsWith("${cacheRoot.path}${File.separator}")
    }

    private fun verifyArchivePackage(file: File): Boolean {
        val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageArchiveInfo(
                file.absolutePath,
                PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES.toLong())
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageArchiveInfo(
                file.absolutePath,
                PackageManager.GET_SIGNING_CERTIFICATES
            )
        } ?: return false

        if (packageInfo.packageName != packageName) {
            return false
        }

        return signaturesMatch(packageInfo)
    }

    private fun signaturesMatch(archiveInfo: android.content.pm.PackageInfo): Boolean {
        val installedInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES.toLong())
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        }

        return signingDigests(installedInfo).intersect(signingDigests(archiveInfo)).isNotEmpty()
    }

    private fun signingDigests(packageInfo: android.content.pm.PackageInfo): Set<Int> {
        val signingInfo = packageInfo.signingInfo ?: return emptySet()
        val signatures = if (signingInfo.hasMultipleSigners()) {
            signingInfo.apkContentsSigners
        } else {
            signingInfo.signingCertificateHistory
        }
        return signatures.map { it.toByteArray().contentHashCode() }.toSet()
    }
}

/**
 * 接收 PackageInstaller 会话的状态广播，并把结果回给 Dart 侧那个还挂着的 MethodChannel.Result。
 *
 * 在 Manifest 里声明（exported=false），所以它和 MainActivity 不是同一个实例，
 * 只能靠 companion object 里的静态字段传递待回调的 result —— 这是这套 API 的标准用法。
 */
class InstallResultReceiver : BroadcastReceiver() {

    companion object {
        private val mainHandler = Handler(Looper.getMainLooper())
        private var pending: MethodChannel.Result? = null
        private var timeoutTask: Runnable? = null

        /** 记下这次安装要回给 Dart 的 result。只在平台主线程调用。 */
        fun begin(result: MethodChannel.Result) {
            // 理论上同一时刻只会有一次安装；真撞上了也不能让上一个 Future 永远挂着
            pending?.error("SESSION_FAILED", "上一次安装请求被新的安装覆盖", null)
            timeoutTask?.let { mainHandler.removeCallbacks(it) }
            pending = result

            // 兜底超时：commit 之后系统正常会立刻回 STATUS_PENDING_USER_ACTION。
            // 个别 ROM 若一条广播都不回，这里保证更新弹窗不会永远停在「正在安装」上
            val task = Runnable { finish("SESSION_FAILED", "安装请求没有响应，请重试或手动安装") }
            timeoutTask = task
            mainHandler.postDelayed(task, 120_000L)
        }

        /** 安装结果的唯一出口，code 传 null 表示成功。保证 result 只会被回一次。 */
        fun finish(code: String?, message: String?) {
            mainHandler.post {
                val target = pending ?: return@post
                pending = null
                timeoutTask?.let { mainHandler.removeCallbacks(it) }
                timeoutTask = null
                if (code == null) {
                    target.success(null)
                } else {
                    target.error(code, message, null)
                }
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)

        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // 系统把「安装确认界面」的 Intent 塞在这个 extra 里，必须由我们主动拉起。
                // 这是整条链路里唯一一次 startActivity，也是 NO_INSTALLER 的唯一来源。
                val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                }
                if (confirm == null) {
                    Log.e(LOG_TAG, "pending user action without EXTRA_INTENT")
                    finish("NO_INSTALLER", "系统没有返回安装确认界面")
                    return
                }
                try {
                    // 从 Receiver 里启动 Activity 没有任务栈，必须自带 NEW_TASK
                    confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(confirm)
                    // 确认界面已经交给系统了，Dart 侧据此收起更新弹窗
                    finish(null, null)
                } catch (e: Exception) {
                    Log.e(LOG_TAG, "install confirm activity not launchable", e)
                    finish("NO_INSTALLER", "设备上没有可用的安装器")
                }
            }

            PackageInstaller.STATUS_SUCCESS -> finish(null, null)

            else -> {
                Log.e(LOG_TAG, "install session failed: status=$status message=$message")
                finish("SESSION_FAILED", message ?: "安装失败（状态码 $status）")
            }
        }
    }
}
