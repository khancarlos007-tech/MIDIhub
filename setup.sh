#!/bin/bash
set -e
mkdir -p "app"
cat > "app/build.gradle.kts" <<'EOF_MP'
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "cat.midipatch"
    compileSdk = 33
    defaultConfig {
        applicationId = "cat.midipatch"
        minSdk = 26
        targetSdk = 33
        versionCode = 1
        versionName = "1.0"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
EOF_MP
mkdir -p "app/src/main"
cat > "app/src/main/AndroidManifest.xml" <<'EOF_MP'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-feature android:name="android.software.midi" android:required="true" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <application android:label="MidiPatch" android:theme="@android:style/Theme.DeviceDefault">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
        <service android:name=".KeepAliveService" android:exported="false" />
        <service android:name=".HubService" android:exported="true"
            android:permission="android.permission.BIND_MIDI_DEVICE_SERVICE">
            <intent-filter>
                <action android:name="android.media.midi.MidiDeviceService" />
            </intent-filter>
            <meta-data android:name="android.media.midi.MidiDeviceService"
                android:resource="@xml/hub" />
        </service>
    </application>
</manifest>
EOF_MP
mkdir -p "app/src/main/java/cat/midipatch"
cat > "app/src/main/java/cat/midipatch/HubService.kt" <<'EOF_MP'
package cat.midipatch

import android.media.midi.MidiDeviceService
import android.media.midi.MidiReceiver

/** Port virtual: el que arriba a "Hub In" surt per "Hub Out" (que pot llegir qualsevol app). */
class HubService : MidiDeviceService() {
    private val fwd = object : MidiReceiver() {
        override fun onSend(data: ByteArray, offset: Int, count: Int, timestamp: Long) {
            for (r in outputPortReceivers) r.send(data, offset, count, timestamp)
        }
    }
    override fun onGetInputPortReceivers(): Array<MidiReceiver> = arrayOf(fwd)
}
EOF_MP
mkdir -p "app/src/main/java/cat/midipatch"
cat > "app/src/main/java/cat/midipatch/KeepAliveService.kt" <<'EOF_MP'
package cat.midipatch

import android.app.*
import android.content.Intent
import android.os.IBinder

/** Servei en primer pla perquè el sistema no suspengui l'enrutador. */
class KeepAliveService : Service() {
    override fun onBind(i: Intent?): IBinder? = null
    override fun onStartCommand(i: Intent?, f: Int, id: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("midi", "MIDI", NotificationManager.IMPORTANCE_LOW))
        val pi = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, "midi")
            .setContentTitle("MidiPatch actiu")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(pi).setOngoing(true).build()
        startForeground(1, n)
        return START_STICKY
    }
}
EOF_MP
mkdir -p "app/src/main/java/cat/midipatch"
cat > "app/src/main/java/cat/midipatch/MainActivity.kt" <<'EOF_MP'
package cat.midipatch

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.widget.*

class MainActivity : Activity() {
    private lateinit var srcSp: Spinner
    private lateinit var dstSp: Spinner
    private lateinit var list: ListView
    private lateinit var status: TextView
    private var srcs = listOf<Router.Port>()
    private var dsts = listOf<Router.Port>()

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        startForegroundService(Intent(this, KeepAliveService::class.java))
        Router.init(this)

        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 32, 32, 32) }
        fun label(t: String) = TextView(this).apply { text = t; textSize = 16f }
        srcSp = Spinner(this); dstSp = Spinner(this); list = ListView(this); status = TextView(this)
        val btn = Button(this).apply { text = "Connecta" }
        root.addView(label("Origen (sortida MIDI)")); root.addView(srcSp)
        root.addView(label("Destí (entrada MIDI)")); root.addView(dstSp)
        root.addView(btn); root.addView(status)
        root.addView(label("Connexions actives (toca per desconnectar)")); root.addView(list)
        setContentView(root)

        btn.setOnClickListener {
            val s = srcs.getOrNull(srcSp.selectedItemPosition); val d = dsts.getOrNull(dstSp.selectedItemPosition)
            if (s == null || d == null) { status.text = "Tria origen i destí"; return@setOnClickListener }
            Router.connect(s, d) { err -> runOnUiThread { status.text = err ?: "Connectat"; refresh() } }
        }
        list.setOnItemClickListener { _, _, i, _ ->
            Router.links.getOrNull(i)?.let { Router.disconnect(it); refresh() }
        }
        Router.listen { runOnUiThread { refresh() } }
        refresh()
    }

    private fun refresh() {
        srcs = Router.ports(true); dsts = Router.ports(false)
        fun ad(l: List<String>) = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, l)
        srcSp.adapter = ad(srcs.map { it.name }); dstSp.adapter = ad(dsts.map { it.name })
        list.adapter = ArrayAdapter(this, android.R.layout.simple_list_item_1,
            Router.links.map { "${it.src.name}  →  ${it.dst.name}" })
    }
}
EOF_MP
mkdir -p "app/src/main/java/cat/midipatch"
cat > "app/src/main/java/cat/midipatch/Router.kt" <<'EOF_MP'
package cat.midipatch

import android.content.Context
import android.media.midi.*
import android.os.Handler
import android.os.Looper

object Router {
    class Port(val info: MidiDeviceInfo, val index: Int, val isSource: Boolean) {
        val name: String get() {
            val p = info.properties
            val dev = p.getString(MidiDeviceInfo.PROPERTY_NAME)
                ?: p.getString(MidiDeviceInfo.PROPERTY_PRODUCT) ?: "Dispositiu ${info.id}"
            val port = info.ports.firstOrNull { it.portNumber == index &&
                it.type == (if (isSource) MidiDeviceInfo.PortInfo.TYPE_OUTPUT else MidiDeviceInfo.PortInfo.TYPE_INPUT) }?.name
            return if (port.isNullOrEmpty()) "$dev #$index" else "$dev: $port"
        }
    }
    class Link(val src: Port, val dst: Port, val d1: MidiDevice, val d2: MidiDevice,
               val out: MidiOutputPort, val inp: MidiInputPort)

    val links = mutableListOf<Link>()
    private lateinit var mgr: MidiManager
    private val h = Handler(Looper.getMainLooper())

    fun init(c: Context) { mgr = c.applicationContext.getSystemService(Context.MIDI_SERVICE) as MidiManager }

    fun listen(cb: () -> Unit) {
        mgr.registerDeviceCallback(object : MidiManager.DeviceCallback() {
            override fun onDeviceAdded(d: MidiDeviceInfo) = cb()
            override fun onDeviceRemoved(d: MidiDeviceInfo) { links.removeAll { it.src.info.id == d.id || it.dst.info.id == d.id }; cb() }
        }, h)
    }

    @Suppress("DEPRECATION")
    fun ports(sources: Boolean): List<Port> = mgr.devices.flatMap { d ->
        d.ports.filter { it.type == (if (sources) MidiDeviceInfo.PortInfo.TYPE_OUTPUT else MidiDeviceInfo.PortInfo.TYPE_INPUT) }
            .map { Port(d, it.portNumber, sources) }
    }

    fun connect(src: Port, dst: Port, done: (String?) -> Unit) {
        mgr.openDevice(src.info, { d1 ->
            if (d1 == null) return@openDevice done("No s'ha pogut obrir ${src.name}")
            mgr.openDevice(dst.info, { d2 ->
                if (d2 == null) { d1.close(); return@openDevice done("No s'ha pogut obrir ${dst.name}") }
                val out = d1.openOutputPort(src.index)
                val inp = d2.openInputPort(dst.index)
                if (out == null || inp == null) {
                    out?.close(); inp?.close(); d1.close(); d2.close()
                    return@openDevice done("Port ocupat: una altra app ja hi està connectada (${dst.name})")
                }
                out.connect(inp)
                links.add(Link(src, dst, d1, d2, out, inp))
                done(null)
            }, h)
        }, h)
    }

    fun disconnect(l: Link) {
        try { l.out.disconnect(l.inp); l.inp.close(); l.out.close(); l.d1.close(); l.d2.close() } catch (_: Exception) {}
        links.remove(l)
    }
}
EOF_MP
mkdir -p "app/src/main/res/xml"
cat > "app/src/main/res/xml/hub.xml" <<'EOF_MP'
<devices>
    <device manufacturer="MidiPatch" product="MIDI Hub">
        <input-port name="Hub In" />
        <output-port name="Hub Out" />
    </device>
</devices>
EOF_MP
