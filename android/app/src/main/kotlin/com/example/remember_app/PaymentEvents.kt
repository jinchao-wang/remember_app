package com.example.remember_app;

/** 进程内总线：服务 -> Flutter */
object PaymentEvents {
    var listener: ((Double, String, String, String) -> Unit)? = null

    fun post(amount: Double, sourceApp: String, content: String, type: String) {
        listener?.invoke(amount, sourceApp, content, type)
    }
}