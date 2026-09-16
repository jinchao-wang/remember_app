package com.example.remember_app;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;

class MainActivity : FlutterActivity() {

    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startListening" -> result.success(true)
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

    companion object {
        private const val CHANNEL = "remember/payment_listener"
        private const val EVENT_CHANNEL = "remember/payment_events"
    }
}