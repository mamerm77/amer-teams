// Amer Teams browser join (docs/GUESTS.md). The call key arrives wrapped to this page's one-time X25519 key, from a
// host's app, after the host admits this guest. The server never has the key.
(() => {
  const LK = window.LivekitClient, $ = (id) => document.getElementById(id);
  const api = location.port === '8080' ? '' : '/api';      // behind Caddy the API is under /api; straight to the orchestrator in development
  const b64 = (u) => btoa(String.fromCharCode(...new Uint8Array(u))), unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  const enc = new TextEncoder(), dec = new TextDecoder();
  const params = new URLSearchParams(location.search); let code = location.hash.slice(1);
  history.replaceState(null, '', location.pathname + location.search);           // keep the code out of history

  // ---- webinar registration ----
  const slug = params.get('w');
  if (slug && !code) {
    $('pre').hidden = true; $('reg').hidden = false;
    fetch(`${api}/v1/webinars/public/${encodeURIComponent(slug)}`).then((r) => r.json()).then((w) => {
      $('wtitle').textContent = w.title || 'Webinar';
      $('wwhen').textContent = w.starts_at ? new Date(w.starts_at * 1000).toLocaleString() : '';
      if (!w.open) { $('rmsg').textContent = 'Registration is closed.'; $('rgo').disabled = true; }
    });
    $('rgo').onclick = async () => {
      const r = await fetch(`${api}/v1/webinars/public/${encodeURIComponent(slug)}/register`, { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ name: $('rname').value, email: $('remail').value }) });
      const j = await r.json();
      if (!r.ok) { $('rmsg').textContent = j.detail?.[0]?.msg || j.detail || 'Could not register'; return; }
      const link = `${location.origin}${location.pathname}#${j.code}`;
      $('rmsg').innerHTML = ''; const a = document.createElement('a'); a.href = link; a.textContent = 'Your personal join link'; $('rmsg').append('You are registered. Keep this link: ', a);
      code = j.code; $('name').value = $('rname').value; $('pre').hidden = false;
    };
  }

  let room, myKey, guestPk, joined = false, attendee = false; const qs = new Map();
  class Keys extends LK.BaseKeyProvider {
    constructor() { super({ sharedKey: true, ratchetWindowSize: 0, failureTolerance: -1 }); }
    async put(str, idx) { this.onSetEncryptionKey(await LK.createKeyMaterialFromString(str), undefined, idx); }
  }
  const keys = new Keys();

  async function unwrap(m) {
    const epk = unb64(m.epk);
    const shared = await crypto.subtle.deriveBits({ name: 'X25519', public: await crypto.subtle.importKey('raw', epk, { name: 'X25519' }, false, []) }, myKey.privateKey, 256);
    const hk = await crypto.subtle.importKey('raw', shared, 'HKDF', false, ['deriveKey']);
    const salt = new Uint8Array([...epk, ...guestPk]);
    const k = await crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt, info: enc.encode('amer-guest-v1') }, hk, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
    return dec.decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64(m.nonce) }, k, unb64(m.ct)));
  }
  const send = (o) => room.localParticipant.publishData(enc.encode(JSON.stringify(o)), { reliable: true, topic: 'meeting' });

  function renderQa() {
    const ul = $('ql'); ul.innerHTML = '';
    [...qs.values()].sort((a, b) => (a.answered - b.answered) || (b.votes - a.votes)).forEach((q) => {
      const li = document.createElement('li'); li.textContent = `${q.answered ? '✓ ' : ''}${q.q} — ${q.name} (${q.votes}) `;
      if (!q.answered && !q.mine) { const b = document.createElement('button'); b.className = 'sec'; b.textContent = '▲'; b.onclick = () => { q.votes++; q.mine = true; send({ t: 'qa', op: 'vote', id: q.id }); renderQa(); }; li.append(b); }
      ul.append(li);
    });
  }

  function attach(track, p) {
    if (track.kind === 'video') { const v = track.attach(); v.id = `v-${p.identity}-${track.sid}`; $('grid').append(v); }
    else { const a = track.attach(); a.hidden = true; document.body.append(a); }
  }

  $('go').onclick = async () => {
    $('msg').textContent = '';
    if (!code) { $('msg').textContent = 'This page needs a join link from the meeting host.'; return; }
    if (!crypto.subtle || !LK.isE2EESupported()) { $('msg').textContent = 'This browser cannot join an encrypted meeting. Use a current Chrome, Edge, Firefox or Safari.'; return; }
    try { myKey = await crypto.subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']); }
    catch { $('msg').textContent = 'This browser lacks X25519 key support. Use a current Chrome, Edge, Firefox or Safari.'; return; }
    guestPk = new Uint8Array(await crypto.subtle.exportKey('raw', myKey.publicKey));
    const r = await fetch(`${api}/v1/guests/join`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code, name: $('name').value || 'Guest' }) });
    const j = await r.json(); if (!r.ok) { $('msg').textContent = j.detail || 'Could not join'; return; }
    attendee = j.attendee;
    room = new LK.Room({ adaptiveStream: true, dynacast: true, e2ee: { keyProvider: keys, worker: new Worker('/join/livekit-client.e2ee.worker.js') } });
    room.on(LK.RoomEvent.TrackSubscribed, (t, _pub, p) => attach(t, p));
    room.on(LK.RoomEvent.TrackUnsubscribed, (t) => t.detach().forEach((e) => e.remove()));
    room.on(LK.RoomEvent.DataReceived, async (data, p) => {
      let m; try { m = JSON.parse(dec.decode(data)); } catch { return; }
      if (m.t === 'gk' && m.to === j.identity) {
        try { await keys.put(await unwrap(m), m.idx); room.setE2EEEnabled(true);
          if (!joined) { joined = true; $('st').textContent = `Admitted · end-to-end encrypted${attendee ? ' · you are an attendee' : ''}`;
            if (!attendee) { await room.localParticipant.setMicrophoneEnabled(true); await room.localParticipant.setCameraEnabled(true);
              room.localParticipant.videoTrackPublications.forEach((pub) => pub.track && attach(pub.track, room.localParticipant)); } } }
        catch { $('st').textContent = 'Could not read the meeting key'; }
      }
      if (m.t === 'gk-who') send({ t: 'gk-hello', pk: b64(guestPk) });                 // a host asks lobby guests to re-announce
      if (m.t === 'qa') {
        if (m.op === 'ask') qs.set(m.id, { id: m.id, q: m.q, name: m.name || p?.name || 'Someone', votes: 0, answered: false });
        if (m.op === 'vote' && qs.has(m.id)) qs.get(m.id).votes++;
        if (m.op === 'answered' && qs.has(m.id)) qs.get(m.id).answered = true;
        renderQa();
      }
    });
    room.on(LK.RoomEvent.Disconnected, () => { $('st').textContent = 'You have left the meeting'; });
    await room.connect(j.url, j.token);
    $('pre').style.display = 'none'; $('reg').hidden = true; $('call').style.display = 'block';
    $('st').textContent = 'In the lobby: waiting for a host to let you in'; $('mic').hidden = $('cam').hidden = attendee;
    const hello = () => { if (!joined && room.state === 'connected') send({ t: 'gk-hello', pk: b64(guestPk) }).catch(() => {}); };
    hello(); const iv = setInterval(() => joined ? clearInterval(iv) : hello(), 3000);      // until a host lets us in
  };
  $('mic').onclick = async () => { const on = !room.localParticipant.isMicrophoneEnabled; await room.localParticipant.setMicrophoneEnabled(on); $('mic').textContent = on ? 'Mute' : 'Unmute'; };
  $('cam').onclick = async () => { const on = !room.localParticipant.isCameraEnabled; await room.localParticipant.setCameraEnabled(on); $('cam').textContent = on ? 'Stop video' : 'Start video'; };
  $('leave').onclick = () => room?.disconnect();
  $('ask').onclick = () => { const q = $('q').value.trim(); if (!q || !room) return; const id = `q-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
    qs.set(id, { id, q, name: 'You', votes: 0, answered: false, mine: true }); send({ t: 'qa', op: 'ask', id, q, name: $('name').value || 'Guest' }); $('q').value = ''; renderQa(); };
})();
