package com.example.sertifikat_kegiatan

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHODS_CHANNEL = "com.walletconnect.flutterdapp/methods"
        private const val EVENTS_CHANNEL = "com.walletconnect.flutterdapp/events"
    }

    private var eventSink: EventChannel.EventSink? = null
    private var pendingLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    pendingLink?.let {
                        eventSink?.success(it)
                        pendingLink = null
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHODS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialLink" -> {
                        pendingLink?.let {
                            eventSink?.success(it)
                            pendingLink = null
                        } ?: run {
                            intent?.dataString?.let { link ->
                                eventSink?.success(link)
                                intent?.data = null
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        intent?.dataString?.let { pendingLink = it }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.dataString?.let { link ->
            if (eventSink != null) {
                eventSink?.success(link)
            } else {
                pendingLink = link
            }
        }
    }
}
