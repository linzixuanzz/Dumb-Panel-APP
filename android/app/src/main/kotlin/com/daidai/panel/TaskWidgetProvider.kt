package com.daidai.panel

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * 桌面小组件「呆呆面板 · 任务」（APP v2.0，design §6）。
 *
 * 只读 APP 写下的快照（home_widget 的 SharedPreferences），自己**不联网**：
 * 键名与 Dart 侧 `lib/core/integration/integration_data.dart` 的 `WidgetKeys` 一一对应，两边要一起改。
 * 所有值都是字符串，时间是毫秒时间戳。
 *
 * 点按通过启动 URI 打开 APP：`daidai://overview`、`daidai://tasks`、`daidai://task/<id>`，
 * 由 Dart 侧 `launchActionFromWidgetUri` 解析。
 */
class TaskWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val now = System.currentTimeMillis()
        for (widgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.task_widget)

            // ── 今日成功率：成功 / (成功 + 失败)，与概览同口径；快照不是今天的就显示「--」 ──
            val todayDate = widgetData.getString("dd_today_date", null)
            val success = widgetData.getString("dd_today_success", null)?.toIntOrNull()
            val failed = widgetData.getString("dd_today_failed", null)?.toIntOrNull()
            if (todayDate == dateKey(now) && success != null && failed != null) {
                val finished = success + failed
                views.setTextViewText(
                    R.id.widget_rate,
                    if (finished == 0) "--" else "${Math.round(success * 100.0 / finished)}%",
                )
                views.setTextViewText(
                    R.id.widget_rate_detail,
                    if (finished == 0) "今天还没有执行" else "成功 $success · 失败 $failed",
                )
            } else {
                views.setTextViewText(R.id.widget_rate, "--")
                views.setTextViewText(R.id.widget_rate_detail, "打开概览刷新")
            }

            // ── 更新时间：让人知道这份快照有多旧 ──
            val updatedAt = widgetData.getString("dd_updated_at", null)?.toLongOrNull()
            views.setTextViewText(
                R.id.widget_updated,
                if (updatedAt == null) "打开 APP 获取数据" else "更新于 ${formatTime(updatedAt, now)}",
            )

            // ── 下一个任务：时间已经过了说明快照旧了，提示刷新而不是显示一个过去的「下一个」 ──
            val nextId = widgetData.getString("dd_next_id", null)
            val nextName = widgetData.getString("dd_next_name", null)
            val nextAt = widgetData.getString("dd_next_at", null)?.toLongOrNull()
            if (nextName.isNullOrEmpty() || nextAt == null) {
                views.setTextViewText(R.id.widget_next_name, "暂无")
                views.setTextViewText(R.id.widget_next_time, "")
            } else {
                views.setTextViewText(R.id.widget_next_name, nextName)
                views.setTextViewText(
                    R.id.widget_next_time,
                    if (nextAt < now) "待刷新" else formatTime(nextAt, now),
                )
            }

            // ── 最近失败的任务 ──
            val failedId = widgetData.getString("dd_failed_id", null)
            val failedName = widgetData.getString("dd_failed_name", null)
            val failedAt = widgetData.getString("dd_failed_at", null)?.toLongOrNull()
            if (failedName.isNullOrEmpty()) {
                views.setTextViewText(R.id.widget_failed_name, "暂无")
                views.setTextViewText(R.id.widget_failed_time, "")
            } else {
                views.setTextViewText(R.id.widget_failed_name, failedName)
                views.setTextViewText(
                    R.id.widget_failed_time,
                    if (failedAt == null) "" else formatTime(failedAt, now),
                )
            }

            // ── 点按：整卡 → 任务页；成功率 → 概览；两行 → 对应任务的详情弹层 ──
            views.setOnClickPendingIntent(android.R.id.background, launch(context, "daidai://tasks"))
            views.setOnClickPendingIntent(R.id.widget_rate_block, launch(context, "daidai://overview"))
            views.setOnClickPendingIntent(
                R.id.widget_next_row,
                launch(context, if (nextId.isNullOrEmpty()) "daidai://tasks" else "daidai://task/$nextId"),
            )
            views.setOnClickPendingIntent(
                R.id.widget_failed_row,
                launch(context, if (failedId.isNullOrEmpty()) "daidai://tasks" else "daidai://task/$failedId"),
            )

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    /**
     * 各个点按区域用不同的 URI：PendingIntent 按 Intent 的 data 区分，
     * 同一个 requestCode 也不会互相覆盖。
     */
    private fun launch(context: Context, uri: String) =
        HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse(uri))

    private fun dateKey(millis: Long): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.CHINA).format(Date(millis))

    /** 今天只显示「HH:mm」，昨天 / 明天带前缀，其他日子带「M月d日」。 */
    private fun formatTime(millis: Long, now: Long): String {
        val time = SimpleDateFormat("HH:mm", Locale.CHINA).format(Date(millis))
        // 两边都取当天零点再相除，四舍五入抵消夏令时的 ±1 小时
        val dayDiff = Math.round((startOfDay(millis) - startOfDay(now)) / 86_400_000.0)
        return when (dayDiff) {
            0L -> time
            1L -> "明天 $time"
            -1L -> "昨天 $time"
            else -> SimpleDateFormat("M月d日 HH:mm", Locale.CHINA).format(Date(millis))
        }
    }

    private fun startOfDay(millis: Long): Long =
        Calendar.getInstance().apply {
            timeInMillis = millis
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
}
