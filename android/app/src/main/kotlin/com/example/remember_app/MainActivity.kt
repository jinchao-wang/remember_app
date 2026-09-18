package com.example.remember_app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startListening" -> {
                    result.success(true)
                    // 引导用户到系统设置开启通知权限
                    openNotificationSettings()
                }
                "isListeningEnabled" -> {
                    val enabled = PaymentNotificationListenerService.isNotificationListeningEnabled(this)
                    result.success(enabled)
                }
                "openNotificationSettings" -> {
                    openNotificationSettings()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    PaymentEvents.listener = { amount, sourceApp, content, type ->
                        eventSink?.success(mapOf(
                            "amount" to amount,
                            "sourceApp" to sourceApp,
                            "content" to content,
                            "type" to type
                        ))
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    PaymentEvents.listener = null
                }
            }
        )
    }

    override fun onDestroy() {
        eventSink = null
        PaymentEvents.listener = null
        super.onDestroy()
    }

    private fun openNotificationSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        } else {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        }
    }

    companion object {
        private const val CHANNEL = "remember/payment_listener"
        private const val EVENT_CHANNEL = "remember/payment_events"
    }
}