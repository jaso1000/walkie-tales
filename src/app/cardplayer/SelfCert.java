package app.cardplayer;

import android.content.Context;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.math.BigInteger;
import java.net.InetAddress;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;

/**
 * A home-made certificate for the player's https address (browsers only allow the microphone, for voice messages,
 * on a secure address). Made once on the phone (an RSA key and a self-signed X.509 certificate written out by hand,
 * since Android has no public API for making one), kept in the app's private files, and made again if the player's
 * address changes. The browser warns about it once; nothing here is trusted by anything else.
 */
final class SelfCert {
    private static final char[] PASS = "walkietales".toCharArray();

    static SSLContext context(Context c, String ip) throws Exception {
        File f = new File(c.getFilesDir(), "https.bks");
        String want = ip == null ? "" : ip;
        KeyStore ks = KeyStore.getInstance(KeyStore.getDefaultType());
        boolean ok = false;
        if (f.isFile() && want.equals(Store.prefs(c).getString("https_ip", ""))) {
            try (FileInputStream in = new FileInputStream(f)) { ks.load(in, PASS); ok = ks.containsAlias("player"); } catch (Exception e) { ok = false; }
        }
        if (!ok) {
            KeyPairGenerator g = KeyPairGenerator.getInstance("RSA");
            g.initialize(2048, new SecureRandom());
            KeyPair kp = g.generateKeyPair();
            X509Certificate cert = make(kp, want);
            ks.load(null, null);
            ks.setKeyEntry("player", kp.getPrivate(), PASS, new Certificate[]{cert});
            try (FileOutputStream out = new FileOutputStream(f)) { ks.store(out, PASS); }
            Store.prefs(c).edit().putString("https_ip", want).apply();
        }
        KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        kmf.init(ks, PASS);
        SSLContext ssl = SSLContext.getInstance("TLS");
        ssl.init(kmf.getKeyManagers(), null, null);
        return ssl;
    }

    // ------------------------------------------------------------ the certificate, in DER

    private static final byte[] SHA256_RSA = {0x06, 0x09, 0x2A, (byte) 0x86, 0x48, (byte) 0x86, (byte) 0xF7, 0x0D, 0x01, 0x01, 0x0B};
    private static final byte[] CN = {0x06, 0x03, 0x55, 0x04, 0x03};
    private static final byte[] SAN = {0x06, 0x03, 0x55, 0x1D, 0x11};

    static X509Certificate make(KeyPair kp, String ip) throws Exception {
        byte[] alg = tlv(0x30, cat(SHA256_RSA, new byte[]{0x05, 0x00}));
        byte[] name = tlv(0x30, tlv(0x31, tlv(0x30, cat(CN, tlv(0x0C, "WalkieTales player".getBytes("UTF-8"))))));
        long now = System.currentTimeMillis();
        byte[] validity = tlv(0x30, cat(time(now - 86_400_000L), time(now + 3650L * 86_400_000L)));
        byte[] names = tlv(0x82, "localhost".getBytes("US-ASCII"));
        if (!ip.isEmpty()) names = cat(names, tlv(0x87, InetAddress.getByName(ip).getAddress()));
        byte[] ext = tlv(0xA3, tlv(0x30, tlv(0x30, cat(SAN, tlv(0x04, tlv(0x30, names))))));
        byte[] serial = tlv(0x02, new BigInteger(64, new SecureRandom()).add(BigInteger.ONE).toByteArray());
        byte[] tbs = tlv(0x30, cat(new byte[]{(byte) 0xA0, 0x03, 0x02, 0x01, 0x02}, serial, alg, name, validity, name,
                kp.getPublic().getEncoded(), ext));
        Signature s = Signature.getInstance("SHA256withRSA");
        s.initSign(kp.getPrivate());
        s.update(tbs);
        byte[] sig = cat(new byte[]{0x00}, s.sign());
        byte[] der = tlv(0x30, cat(tbs, alg, tlv(0x03, sig)));
        return (X509Certificate) CertificateFactory.getInstance("X.509").generateCertificate(new java.io.ByteArrayInputStream(der));
    }

    /** UTCTime (dates before 2050) or GeneralizedTime. */
    private static byte[] time(long ms) throws Exception {
        Date d = new Date(ms);
        SimpleDateFormat y = new SimpleDateFormat("yyyy", Locale.ROOT);
        y.setTimeZone(TimeZone.getTimeZone("UTC"));
        boolean utc = Integer.parseInt(y.format(d)) < 2050;
        SimpleDateFormat f = new SimpleDateFormat(utc ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'", Locale.ROOT);
        f.setTimeZone(TimeZone.getTimeZone("UTC"));
        return tlv(utc ? 0x17 : 0x18, f.format(d).getBytes("US-ASCII"));
    }

    private static byte[] tlv(int tag, byte[] v) {
        ByteArrayOutputStream o = new ByteArrayOutputStream();
        o.write(tag);
        int n = v.length;
        if (n < 0x80) o.write(n);
        else if (n < 0x100) { o.write(0x81); o.write(n); }
        else if (n < 0x10000) { o.write(0x82); o.write(n >> 8); o.write(n & 0xFF); }
        else { o.write(0x83); o.write(n >> 16); o.write((n >> 8) & 0xFF); o.write(n & 0xFF); }
        o.write(v, 0, n);
        return o.toByteArray();
    }

    private static byte[] cat(byte[]... parts) {
        ByteArrayOutputStream o = new ByteArrayOutputStream();
        for (byte[] p : parts) o.write(p, 0, p.length);
        return o.toByteArray();
    }

    private SelfCert() { }
}
