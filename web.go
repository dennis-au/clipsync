package main

const loginHTML = `<!DOCTYPE html>
<html lang="es"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light"><title>clipsync · acceso</title>
<style>
  :root{--bg:#0d1117;--pan:#161b22;--bd:#30363d;--tx:#e6edf3;--mut:#8b949e;--acc:#2f81f7;--bad:#f85149}
  *{box-sizing:border-box}
  body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;font:15px/1.5 -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--tx)}
  form{background:var(--pan);border:1px solid var(--bd);border-radius:12px;padding:28px;width:320px;max-width:90vw;text-align:center}
  h1{font-size:20px;margin:0 0 4px}
  p{color:var(--mut);font-size:13px;margin:0 0 18px}
  input{width:100%;padding:11px;border:1px solid var(--bd);border-radius:8px;background:var(--bg);color:var(--tx);font:inherit;margin-bottom:12px}
  button{width:100%;padding:11px;border:0;border-radius:8px;background:var(--acc);color:#fff;font-weight:600;cursor:pointer;font:inherit}
  .err{color:var(--bad);font-size:13px;margin-bottom:10px;min-height:18px}
</style></head>
<body>
<form method="POST" action="login">
  <h1>🔒 clipsync</h1>
  <p>Introduce la contraseña para acceder</p>
  <div class="err"><!--ERR--></div>
  <input type="password" name="password" placeholder="contraseña" autofocus autocomplete="current-password">
  <button type="submit">Entrar</button>
</form>
</body></html>`

const indexHTML = `<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>clipsync · portapapeles compartido</title>
<style>
  :root{--bg:#0d1117;--pan:#161b22;--bd:#30363d;--tx:#e6edf3;--mut:#8b949e;--acc:#2f81f7;--ok:#3fb950;--bad:#f85149}
  *{box-sizing:border-box}
  body{margin:0;font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--tx)}
  .wrap{max-width:860px;margin:0 auto;padding:18px 16px 80px}
  header{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:14px}
  h1{font-size:18px;margin:0;font-weight:600}
  .dot{width:9px;height:9px;border-radius:50%;background:var(--mut);display:inline-block}
  .dot.on{background:var(--ok);box-shadow:0 0 8px var(--ok)}
  .dot.off{background:var(--bad)}
  .status{color:var(--mut);font-size:13px}
  .row{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:10px 0}
  input,button,textarea{font:inherit;color:var(--tx);background:var(--pan);border:1px solid var(--bd);border-radius:8px}
  input{padding:8px 10px;flex:1;min-width:160px}
  button{padding:8px 14px;cursor:pointer;background:var(--pan)}
  button:hover{border-color:var(--acc)}
  button.primary{background:var(--acc);border-color:var(--acc);color:#fff;font-weight:600}
  textarea{width:100%;min-height:96px;padding:12px;resize:vertical;line-height:1.45;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:14px}
  .hint{color:var(--mut);font-size:12px;margin:2px 0 0}
  .hint kbd{background:var(--pan);border:1px solid var(--bd);border-bottom-width:2px;border-radius:5px;padding:0 5px;font-size:11px}
  .drop{border:1.5px dashed var(--bd);border-radius:10px;padding:10px;text-align:center;color:var(--mut);font-size:13px;margin:8px 0}
  .drop.hot{border-color:var(--acc);color:var(--tx);background:rgba(47,129,247,.08)}
  .feed{margin-top:18px}
  .feed h2{font-size:13px;color:var(--mut);font-weight:600;text-transform:uppercase;letter-spacing:.04em;margin:0 0 10px;display:flex;justify-content:space-between}
  .card{background:var(--pan);border:1px solid var(--bd);border-radius:10px;padding:10px 12px;margin-bottom:8px;display:flex;gap:12px;align-items:flex-start;cursor:pointer;transition:.12s}
  .card:hover{border-color:var(--acc)}
  .card.pinned{border-color:#d29922;background:linear-gradient(0deg,rgba(210,153,34,.06),rgba(210,153,34,.06)),var(--pan)}
  .card .act button.on{border-color:#d29922;color:#d29922}
  .card .body{flex:1;min-width:0}
  .card pre{margin:0;white-space:pre-wrap;word-break:break-word;font-family:ui-monospace,monospace;font-size:13px;max-height:120px;overflow:hidden}
  .card img{max-height:120px;max-width:220px;border-radius:6px;border:1px solid var(--bd);display:block}
  .card .meta{color:var(--mut);font-size:11px;margin-top:6px;display:flex;gap:8px;align-items:center}
  .badge{font-size:10px;padding:1px 6px;border-radius:20px;border:1px solid var(--bd);color:var(--mut)}
  .card .act{display:flex;flex-direction:column;gap:6px}
  .card .act button{padding:5px 9px;font-size:12px}
  .empty{color:var(--mut);font-size:13px;padding:20px;text-align:center;border:1px dashed var(--bd);border-radius:10px}
  .toast{position:fixed;bottom:18px;left:50%;transform:translateX(-50%);background:var(--ok);color:#04130a;padding:9px 16px;border-radius:8px;font-weight:600;opacity:0;transition:.2s;pointer-events:none;z-index:9}
  .toast.show{opacity:1}
  .toast.err{background:var(--bad);color:#fff}
  a{color:var(--acc)}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <span class="dot" id="dot"></span>
    <h1>clipsync</h1>
    <span class="status" id="status">conectando…</span>
  </header>

  <div class="row">
    <input id="room" placeholder="código de sala (secreto compartido)" autocomplete="off" spellcheck="false">
    <button id="join">Entrar</button>
    <button id="rnd" title="generar código aleatorio">🎲</button>
  </div>

  <div class="drop" id="drop">Pega aquí con <kbd>Ctrl/Cmd</kbd>+<kbd>V</kbd> (texto o imagen) — cada pegado es un item · o suelta una imagen</div>

  <textarea id="box" placeholder="Escribe a mano y pulsa Enviar (o Enter). Para copiar/pegar usa Ctrl+V: cada pegado se cierra como un item."></textarea>
  <div class="row">
    <button class="primary" id="send">Enviar texto</button>
    <span class="hint"><kbd>Enter</kbd> envía · <kbd>Shift</kbd>+<kbd>Enter</kbd> salto de línea</span>
  </div>

  <div class="feed">
    <h2><span>Historial de la sala</span><span id="count"></span></h2>
    <div id="feed"></div>
  </div>
</div>
<div class="toast" id="toast"></div>

<script>
(function(){
  var $=function(s){return document.querySelector(s)};
  var box=$('#box'),dot=$('#dot'),status=$('#status'),feed=$('#feed');
  var es=null, room='', seen={};
  var me = (localStorage.getItem('clipsync.me')||('web-'+Math.random().toString(36).slice(2,6)));
  localStorage.setItem('clipsync.me',me);

  function toast(m,err){var t=$('#toast');t.textContent=m;t.className='toast show'+(err?' err':'');setTimeout(function(){t.className='toast'},1400)}
  function chk(r){if(r.status===401){location.reload();throw 0}return r}
  function setStatus(s,cls){status.textContent=s;dot.className='dot'+(cls?' '+cls:'')}
  function fmtAt(ts){if(!ts)return'';var d=new Date(ts*1000);return d.toLocaleString()}
  function human(n){if(n<1024)return n+' B';if(n<1048576)return (n/1024).toFixed(0)+' KB';return (n/1048576).toFixed(1)+' MB'}

  // ---- copiar item al portapapeles del SO ----
  function copyText(t){
    if(navigator.clipboard&&navigator.clipboard.writeText){
      return navigator.clipboard.writeText(t).then(function(){toast('Copiado')}).catch(function(){fallbackCopy(t)})
    }
    fallbackCopy(t)
  }
  function fallbackCopy(t){
    var ta=document.createElement('textarea');ta.value=t;document.body.appendChild(ta);ta.select();
    try{document.execCommand('copy');toast('Copiado')}catch(e){toast('No se pudo copiar',1)}
    document.body.removeChild(ta)
  }
  function copyItem(it){
    if(it.kind==='image'){
      fetch('blob?room='+encodeURIComponent(room)+'&id='+encodeURIComponent(it.id)).then(function(r){return r.blob()}).then(function(b){
        if(navigator.clipboard&&window.ClipboardItem){
          var o={};o[b.type]=b;
          return navigator.clipboard.write([new ClipboardItem(o)]).then(function(){toast('Imagen copiada')})
        }
        throw new Error('no clipboard image')
      }).catch(function(){toast('Tu navegador no deja copiar imágenes; ábrela y guárdala',1)});
      return
    }
    if(it.trunc){ // texto recortado: pedir completo
      fetch('item?room='+encodeURIComponent(room)+'&id='+encodeURIComponent(it.id)).then(function(r){return r.json()}).then(function(f){copyText(f.text)}).catch(function(){copyText(it.text)})
    }else{copyText(it.text)}
  }

  // ---- render ----
  function card(it){
    var c=document.createElement('div');c.className='card'+(it.pinned?' pinned':'');c.dataset.id=it.id;
    var body=document.createElement('div');body.className='body';
    if(it.kind==='image'){
      var img=document.createElement('img');img.loading='lazy';img.src='blob?room='+encodeURIComponent(room)+'&id='+encodeURIComponent(it.id);body.appendChild(img)
    }else{
      var pre=document.createElement('pre');pre.textContent=it.text||'';body.appendChild(pre)
    }
    var meta=document.createElement('div');meta.className='meta';
    meta.innerHTML='<span class="badge">'+(it.kind==='image'?'🖼 imagen':'📝 texto')+'</span><span>'+(it.from||'?')+'</span><span>'+fmtAt(it.at)+'</span><span>'+human(it.size||0)+'</span>'+(it.pinned?'<span class="badge">📌 fijado</span>':'');
    body.appendChild(meta);
    var act=document.createElement('div');act.className='act';
    var b=document.createElement('button');b.textContent='📋';b.title='Copiar';
    var p=document.createElement('button');p.textContent='📌';p.title=it.pinned?'Quitar fijado':'Fijar (no caduca)';if(it.pinned)p.className='on';
    act.appendChild(b);act.appendChild(p);
    c.appendChild(body);c.appendChild(act);
    var doCopy=function(e){e.stopPropagation();copyItem(it)};
    c.onclick=doCopy;b.onclick=doCopy;
    p.onclick=function(e){e.stopPropagation();togglePin(it)};
    return c
  }
  function togglePin(it){
    var np=it.pinned?0:1;
    fetch('pin?room='+encodeURIComponent(room)+'&id='+encodeURIComponent(it.id)+'&pin='+np,{method:'POST'})
      .then(chk).then(function(r){return r.json()}).then(function(u){updateCard(u);toast(u.pinned?'Fijado':'Desfijado')}).catch(function(){})
  }
  function updateCard(it){
    var old=feed.querySelector('.card[data-id="'+(window.CSS&&CSS.escape?CSS.escape(it.id):it.id)+'"]');
    var nc=card(it);
    if(old){old.parentNode.replaceChild(nc,old)}else{prepend(it)}
  }
  function prepend(it){
    if(seen[it.id]){updateCard(it);return} seen[it.id]=1;
    var e=$('#empty'); if(e)e.remove();
    feed.insertBefore(card(it),feed.firstChild);
    updateCount()
  }
  function renderAll(items){
    feed.innerHTML='';seen={};
    if(!items||!items.length){feed.innerHTML='<div class="empty" id="empty">Aún no hay nada en esta sala. Pega algo con Ctrl+V.</div>';updateCount();return}
    items.forEach(function(it){seen[it.id]=1;feed.appendChild(card(it))}); // items vienen antiguo->nuevo
    // queremos nuevo arriba:
    var kids=Array.prototype.slice.call(feed.children).reverse();feed.innerHTML='';kids.forEach(function(k){feed.appendChild(k)});
    updateCount()
  }
  function updateCount(){var n=feed.querySelectorAll('.card').length;$('#count').textContent=n?(n+' items'):''}

  // ---- envío ----
  function pushText(t){
    if(!room||!t)return;
    fetch('push?room='+encodeURIComponent(room),{method:'POST',headers:{'X-From':me,'X-Kind':'text'},body:t})
      .then(chk).then(function(r){if(!r.ok)throw 0;return r.json()}).then(function(it){prepend(it);toast('Enviado')}).catch(function(){toast('Error al enviar',1)})
  }
  function pushImage(blob){
    if(!room||!blob)return;
    fetch('push?room='+encodeURIComponent(room),{method:'POST',headers:{'X-From':me,'X-Kind':'image','X-Mime':blob.type||'image/png','Content-Type':blob.type||'image/png'},body:blob})
      .then(chk).then(function(r){if(!r.ok)throw 0;return r.json()}).then(function(it){prepend(it);toast('Imagen enviada')}).catch(function(){toast('Error al enviar imagen',1)})
  }

  function sendManual(){var t=box.value;if(!t.trim())return;pushText(t);box.value=''}
  $('#send').onclick=sendManual;
  box.addEventListener('keydown',function(e){if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();sendManual()}});

  // ---- Ctrl+V global => item atómico (texto o imagen), sin tocar la caja ----
  document.addEventListener('paste',function(e){
    if(!room){toast('Entra en una sala primero',1);return}
    var dt=e.clipboardData;if(!dt)return;
    var imgs=[];
    if(dt.items){for(var i=0;i<dt.items.length;i++){var it=dt.items[i];if(it.kind==='file'&&it.type.indexOf('image')===0){var f=it.getAsFile();if(f)imgs.push(f)}}}
    if(imgs.length){e.preventDefault();imgs.forEach(pushImage);return}
    var txt=dt.getData('text');
    if(txt){e.preventDefault();pushText(txt)}
  });

  // ---- drag & drop de imágenes ----
  var drop=$('#drop');
  ['dragenter','dragover'].forEach(function(ev){drop.addEventListener(ev,function(e){e.preventDefault();drop.classList.add('hot')})});
  ['dragleave','drop'].forEach(function(ev){drop.addEventListener(ev,function(e){e.preventDefault();drop.classList.remove('hot')})});
  drop.addEventListener('drop',function(e){var fs=e.dataTransfer.files;for(var i=0;i<fs.length;i++){if(fs[i].type.indexOf('image')===0)pushImage(fs[i])}});

  // ---- SSE ----
  function connect(){
    if(es){es.close();es=null}
    if(!room)return;
    setStatus('conectando…');
    es=new EventSource('events?room='+encodeURIComponent(room));
    es.onopen=function(){setStatus('en vivo · sala "'+room+'"','on')};
    es.onmessage=function(ev){try{var m=JSON.parse(ev.data);if(m.kind==='snapshot')renderAll(m.items);else if(m.kind==='push')prepend(m.item);else if(m.kind==='update')updateCard(m.item)}catch(e){}};
    es.onerror=function(){setStatus('reconectando…','off')};
  }

  function setRoom(r){
    room=(r||'').trim();if(!room)return;
    $('#room').value=room;localStorage.setItem('clipsync.room',room);location.hash=encodeURIComponent(room);
    seen={};feed.innerHTML='';connect();
    fetch('list?room='+encodeURIComponent(room)).then(chk).then(function(r){return r.json()}).then(function(d){renderAll(d.items)}).catch(function(){})
  }
  $('#join').onclick=function(){setRoom($('#room').value)};
  $('#room').addEventListener('keydown',function(e){if(e.key==='Enter')setRoom($('#room').value)});
  $('#rnd').onclick=function(){var c=(crypto&&crypto.getRandomValues)?Array.from(crypto.getRandomValues(new Uint8Array(8))).map(function(b){return b.toString(36)}).join('').slice(0,12):Math.random().toString(36).slice(2,12);$('#room').value=c;setRoom(c)};

  var initial=decodeURIComponent((location.hash||'').replace(/^#/,''))||localStorage.getItem('clipsync.room')||'';
  if(initial){setRoom(initial)}else{setStatus('elige un código de sala','off');renderAll([])}
  window.addEventListener('hashchange',function(){var h=decodeURIComponent((location.hash||'').replace(/^#/,''));if(h&&h!==room)setRoom(h)});
})();
</script>
</body>
</html>`
