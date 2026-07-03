package com.llmsandbox.androide2e

import android.app.Activity
import android.os.Bundle
import android.widget.Button
import android.widget.TextView

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val statusText = findViewById<TextView>(R.id.statusText)
        val tapButton = findViewById<Button>(R.id.tapButton)

        tapButton.setOnClickListener {
            statusText.text = getString(R.string.status_tapped)
        }
    }
}
