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
        <service android:name=".HubServiceA" android:exported="true"
            android:permission="android.permission.BIND_MIDI_DEVICE_SERVICE">
            <intent-filter>
                <action android:name="android.media.midi.MidiDeviceService" />
            </intent-filter>
            <meta-data android:name="android.media.midi.MidiDeviceService"
                android:resource="@xml/hub_a" />
        </service>
        <service android:name=".HubServiceB" android:exported="true"
            android:permission="android.permission.BIND_MIDI_DEVICE_SERVICE">
            <intent-filter>
                <action android:name="android.media.midi.MidiDeviceService" />
            </intent-filter>
            <meta-data android:name="android.media.midi.MidiDeviceService"
                android:resource="@xml/hub_b" />
        </service>
    </application>
</manifest>
EOF_MP
mkdir -p "app/src/main/java/cat/midipatch"
cat > "app/src/main/java/cat/midipatch/HubService.kt" <<'EOF_MP'
package cat.midipatch

import android.media.midi.MidiDeviceService
import android.media.midi.MidiReceiver

/** Dispositiu virtual. Tot el que hi arriba surt pel dispositiu "germà" (A <-> B) i per les connexions del patchbay. */
open class HubService(private val id: Int) : MidiDeviceService() {
    override fun onCreate() {
        super.onCreate()
        Router.hubOut[id] = { outputPortReceivers }
    }
    private val fromApp = object : MidiReceiver() {
        override fun onSend(data: ByteArray, offset: Int, count: Int, timestamp: Long) =
            Router.fromHub(id, data, offset, count, timestamp)
    }
    override fun onGetInputPortReceivers(): Array<MidiReceiver> = arrayOf(fromApp)
}
class HubServiceA : HubService(1)
class HubServiceB : HubService(2)
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
    private lateinit var diag: TextView
    private lateinit var mon: TextView
    private val tick = object : Runnable { override fun run() { mon.text = Router.monitor(); mon.postDelayed(this, 300) } }
    private var srcs = listOf<Router.Port>()
    private var dsts = listOf<Router.Port>()

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        startForegroundService(Intent(this, KeepAliveService::class.java))
        Router.init(this)

        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 32, 32, 32) }
        fun label(t: String) = TextView(this).apply { text = t; textSize = 16f }
        srcSp = Spinner(this); dstSp = Spinner(this); list = ListView(this); status = TextView(this); diag = TextView(this); mon = TextView(this)
        val btn = Button(this).apply { text = "Connecta" }
        root.addView(label("Origen (sortida MIDI)")); root.addView(srcSp)
        root.addView(label("Destí (entrada MIDI)")); root.addView(dstSp)
        root.addView(btn); root.addView(status)
        root.addView(label("Monitor MIDI (rebut pels dispositius virtuals)")); root.addView(mon)
        root.addView(label("Connexions actives (toca per desconnectar)")); root.addView(list, LinearLayout.LayoutParams(-1, 500))
        root.addView(label("Dispositius MIDI del sistema (en l'ordre real)")); root.addView(diag)
        setContentView(ScrollView(this).apply { addView(root) })

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
        mon.post(tick)
    }
    override fun onDestroy() { mon.removeCallbacks(tick); super.onDestroy() }

    private fun refresh() {
        diag.text = Router.diag()
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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

object Router {
    /** hub: 0 = dispositiu real; 1 = MidiPatch A; 2 = MidiPatch B. */
    class Port(val info: MidiDeviceInfo?, val index: Int, val isSource: Boolean, val hub: Int = 0) {
        val name: String get() {
            val i = info ?: return "MidiPatch ${if (hub == 1) "A" else "B"}: " +
                if (isSource) "el que envia l'app" else "cap a l'app"
            val p = i.properties
            val dev = p.getString(MidiDeviceInfo.PROPERTY_NAME)
                ?: p.getString(MidiDeviceInfo.PROPERTY_PRODUCT) ?: "Dispositiu ${i.id}"
            val t = if (isSource) MidiDeviceInfo.PortInfo.TYPE_OUTPUT else MidiDeviceInfo.PortInfo.TYPE_INPUT
            val port = i.ports.firstOrNull { it.portNumber == index && it.type == t }?.name
            return if (port.isNullOrEmpty()) "$dev #$index" else "$dev: $port"
        }
    }
    class Link(val src: Port, val dst: Port, val devs: List<MidiDevice>,
               val out: MidiOutputPort?, val recv: MidiReceiver, val inp: MidiInputPort?)

    val links = mutableListOf<Link>()
    private lateinit var mgr: MidiManager
    private val h = Handler(Looper.getMainLooper())

    // --- Hubs interns (1 = A, 2 = B) ---
    val hubOut = ConcurrentHashMap<Int, () -> Array<MidiReceiver>>()
    private val hubSinks = mapOf(1 to CopyOnWriteArrayList<MidiReceiver>(), 2 to CopyOnWriteArrayList<MidiReceiver>())

    /** Dades rebudes pel hub [id]: van al germà (creuat) i a les connexions del patchbay. */
    class Stat { var bytes = 0L; val log = StringBuilder() }
    private val stats = mapOf(1 to Stat(), 2 to Stat())
    fun monitor(): String = stats.entries.joinToString("\n\n") { (id, st) ->
        synchronized(st) { "MidiPatch ${if (id == 1) "A" else "B"}: ${st.bytes} bytes rebuts\n  últims: ${st.log}" }
    }

    fun fromHub(id: Int, d: ByteArray, o: Int, c: Int, t: Long) {
        stats[id]?.let { st -> synchronized(st) {
            st.bytes += c
            for (i in o until o + c) st.log.append(String.format("%02X ", d[i]))
            if (st.log.length > 240) st.log.delete(0, st.log.length - 240)
        } }
        hubOut[3 - id]?.invoke()?.forEach { it.send(d, o, c, t) }
        hubSinks[id]?.forEach { it.send(d, o, c, t) }
    }
    private fun makeTo(id: Int) = object : MidiReceiver() {
        override fun onSend(d: ByteArray, o: Int, c: Int, t: Long) {
            hubOut[id]?.invoke()?.forEach { it.send(d, o, c, t) }
        }
    }
    private val toHub = mapOf(1 to makeTo(1), 2 to makeTo(2))

    fun init(c: Context) { mgr = c.applicationContext.getSystemService(Context.MIDI_SERVICE) as MidiManager }

    fun listen(cb: () -> Unit) {
        mgr.registerDeviceCallback(object : MidiManager.DeviceCallback() {
            override fun onDeviceAdded(d: MidiDeviceInfo) = cb()
            override fun onDeviceRemoved(d: MidiDeviceInfo) {
                links.removeAll { it.src.info?.id == d.id || it.dst.info?.id == d.id }; cb()
            }
        }, h)
    }

    @Suppress("DEPRECATION")
    fun ports(sources: Boolean): List<Port> {
        val t = if (sources) MidiDeviceInfo.PortInfo.TYPE_OUTPUT else MidiDeviceInfo.PortInfo.TYPE_INPUT
        val devs = mgr.devices
            .filter { it.properties.getString(MidiDeviceInfo.PROPERTY_MANUFACTURER) != "MidiPatch" }
            .flatMap { d -> d.ports.filter { it.type == t }.map { Port(d, it.portNumber, sources) } }
        return listOf(Port(null, 0, sources, 1), Port(null, 0, sources, 2)) + devs
    }

    @Suppress("DEPRECATION")
    fun diag(): String = mgr.devices.joinToString("\n\n") { d ->
        val p = d.properties
        val svc = p.getParcelable<android.content.pm.ServiceInfo>("service_info")
        "id ${d.id} · ${p.getString(MidiDeviceInfo.PROPERTY_NAME)}\n" +
        "  fabricant: ${p.getString(MidiDeviceInfo.PROPERTY_MANUFACTURER)} · entrades: ${d.inputPortCount} · sortides: ${d.outputPortCount}\n" +
        "  propietats: " + p.keySet().joinToString { k -> "$k=${p.get(k)}" } + "\n" +
        "  " + (svc?.let { it.packageName + " / " + it.name } ?: "(USB, Bluetooth o sense servei)")
    }

    fun connect(src: Port, dst: Port, done: (String?) -> Unit) {
        val si = src.info; val di = dst.info
        if (si == null && di == null) return done("Origen i destí no poden ser tots dos MidiPatch (ja van creuats A↔B)")
        if (si == null) { // Hub -> dispositiu
            mgr.openDevice(di, { d ->
                if (d == null) return@openDevice done("No s'ha pogut obrir ${dst.name}")
                val inp = d.openInputPort(dst.index)
                if (inp == null) { d.close(); return@openDevice done("Port ocupat: ${dst.name}") }
                hubSinks[src.hub]?.add(inp); links.add(Link(src, dst, listOf(d), null, inp, inp)); done(null)
            }, h)
            return
        }
        if (di == null) { // dispositiu -> Hub
            mgr.openDevice(si, { d ->
                if (d == null) return@openDevice done("No s'ha pogut obrir ${src.name}")
                val out = d.openOutputPort(src.index)
                if (out == null) { d.close(); return@openDevice done("Port no disponible: ${src.name}") }
                val r = toHub.getValue(dst.hub)
                out.connect(r); links.add(Link(src, dst, listOf(d), out, r, null)); done(null)
            }, h)
            return
        }
        mgr.openDevice(si, { d1 ->
            if (d1 == null) return@openDevice done("No s'ha pogut obrir ${src.name}")
            mgr.openDevice(di, { d2 ->
                if (d2 == null) { d1.close(); return@openDevice done("No s'ha pogut obrir ${dst.name}") }
                val out = d1.openOutputPort(src.index); val inp = d2.openInputPort(dst.index)
                if (out == null || inp == null) {
                    out?.close(); inp?.close(); d1.close(); d2.close()
                    return@openDevice done("Port ocupat: una altra app ja hi està connectada (${dst.name})")
                }
                out.connect(inp); links.add(Link(src, dst, listOf(d1, d2), out, inp, inp)); done(null)
            }, h)
        }, h)
    }

    fun disconnect(l: Link) {
        try {
            l.out?.disconnect(l.recv)
            if (l.src.hub != 0) hubSinks[l.src.hub]?.remove(l.recv)
            l.inp?.close(); l.out?.close(); l.devs.forEach { it.close() }
        } catch (_: Exception) {}
        links.remove(l)
    }
}
EOF_MP
mkdir -p "app/src/main/res/xml"
cat > "app/src/main/res/xml/hub_a.xml" <<'EOF_MP'
<devices>
    <device manufacturer="MidiPatch" product="MidiPatch A">
        <input-port name="Rep" />
        <output-port name="Envia" />
    </device>
</devices>
EOF_MP
mkdir -p "app/src/main/res/xml"
cat > "app/src/main/res/xml/hub_b.xml" <<'EOF_MP'
<devices>
    <device manufacturer="MidiPatch" product="MidiPatch B">
        <input-port name="Rep" />
        <output-port name="Envia" />
    </device>
</devices>
EOF_MP
