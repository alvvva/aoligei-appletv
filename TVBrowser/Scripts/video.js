(function () {
  if (window.__tvbVideo) { return; }
  window.__tvbVideo = true;

  var isTop = (window === window.top);
  var hlsSrc = '';
  var last = '';

  function post(obj) {
    var json = JSON.stringify(obj);
    window.__tvbLastReport = json;
    try { window.webkit.messageHandlers.tvb.postMessage(json); } catch (e) {}
  }

  // 记录 hls.js 加载的地址（很多网站用它播放 m3u8，video 元素上只能看到 blob: 地址）
  function hookHls() {
    try {
      var H = window.Hls;
      if (H && H.prototype && H.prototype.loadSource && !H.prototype.__tvb) {
        var orig = H.prototype.loadSource;
        H.prototype.loadSource = function (u) {
          try { hlsSrc = new URL(u, location.href).href; } catch (e) { hlsSrc = String(u); }
          return orig.apply(this, arguments);
        };
        H.prototype.__tvb = true;
      }
    } catch (e) {}
  }

  function playable(u) {
    return typeof u === 'string' && /^https?:\/\//i.test(u) && !/empty\d*\.mp4|blank\.mp4/i.test(u);
  }

  function bestVideo() {
    var vs = document.querySelectorAll('video'), best = null, score = -1;
    for (var i = 0; i < vs.length; i++) {
      var v = vs[i], r = v.getBoundingClientRect(), area = r.width * r.height;
      if (area < 40000) { continue; }
      var s = area + (v.paused ? 0 : 1e9) + (v.currentTime > 0 ? 1e8 : 0);
      if (s > score) { score = s; best = v; }
    }
    return best;
  }

  function firstM3u8() {
    try {
      var es = performance.getEntriesByType('resource');
      for (var i = 0; i < es.length; i++) {
        if (/\.m3u8(\?|$)/i.test(es[i].name)) { return es[i].name; }
      }
    } catch (e) {}
    return '';
  }

  function mediaURL(v) {
    var src = v.currentSrc || v.src || '';
    if (playable(src)) { return src; }
    if (playable(hlsSrc)) { return hlsSrc; }
    return firstM3u8();
  }

  // MacCMS 建站系统（欧乐等）：播放地址和上下集链接都在 player_aaaa 里
  function macInfo() {
    var p = window.player_aaaa;
    if (!p || !p.url) { return null; }
    var url = String(p.url);
    try {
      if (p.encrypt == 1) { url = unescape(url); }
      else if (p.encrypt == 2) { url = unescape(atob(url)); }
    } catch (e) {}
    function abs(u) { try { return u ? new URL(u, location.href).href : ''; } catch (e) { return ''; } }
    return { url: playable(url) ? url : '', next: abs(p.link_next), prev: abs(p.link_pre) };
  }

  function findNext() {
    var as = document.querySelectorAll('a[href]');
    for (var i = 0; i < as.length; i++) {
      var t = (as[i].textContent || '').replace(/\s+/g, '');
      if ((t === '下一集' || t === '下集') && /^https?:/.test(as[i].href) && as[i].href !== location.href) {
        return as[i].href;
      }
    }
    return '';
  }

  function report() {
    hookHls();
    var info = { top: isTop, href: location.href };
    if (isTop) {
      info.title = document.title;
      info.mac = macInfo();
      info.next = (info.mac && info.mac.next) || findNext();
    }
    var v = bestVideo();
    if (v) {
      var r = v.getBoundingClientRect();
      info.video = {
        src: mediaURL(v),
        t: v.currentTime || 0,
        d: isFinite(v.duration) ? v.duration : -1,
        paused: v.paused,
        w: Math.round(r.width),
        h: Math.round(r.height)
      };
    }
    if (!isTop && !v) { return; }
    var key = JSON.stringify([info.href, info.title, info.mac, info.next, v ? [info.video.src, info.video.paused, Math.round(info.video.t / 5), info.video.d] : 0]);
    if (key !== last) { last = key; post(info); }
  }

  // ---- 网页全屏（原生播放器播不了时的备用方案）----
  var fsSaved = [];
  function saveStyle(el) {
    fsSaved.push([el, el.getAttribute('style')]);
  }
  var FS_CSS = 'position:fixed!important;left:0!important;top:0!important;right:auto!important;bottom:auto!important;' +
    'width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;margin:0!important;' +
    'padding:0!important;border:0!important;z-index:2147483647!important;background:#000!important;transform:none!important;';
  function maximize(el, isVideo) {
    saveStyle(el);
    el.style.cssText += ';' + FS_CSS + (isVideo ? 'object-fit:contain!important;' : '');
    var p = el.parentElement;
    while (p && p !== document.documentElement) {
      saveStyle(p);
      p.style.setProperty('transform', 'none', 'important');
      p.style.setProperty('filter', 'none', 'important');
      p.style.setProperty('contain', 'none', 'important');
      p.style.setProperty('overflow', 'visible', 'important');
      p.style.setProperty('z-index', '2147483646', 'important');
      p = p.parentElement;
    }
    document.documentElement.style.setProperty('overflow', 'hidden', 'important');
  }
  function restoreAll() {
    for (var i = fsSaved.length - 1; i >= 0; i--) {
      var el = fsSaved[i][0], st = fsSaved[i][1];
      if (st === null) { el.removeAttribute('style'); } else { el.setAttribute('style', st); }
    }
    fsSaved = [];
    document.documentElement.style.removeProperty('overflow');
  }

  // 在本框架里的 (x, y) 处点击。点到更深一层的框架时继续往里转交。
  function clickAt(x, y) {
    var el = document.elementFromPoint(x, y), guard = 0;
    while (el && el.shadowRoot && el.shadowRoot.elementFromPoint && guard++ < 10) {
      var inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) { break; }
      el = inner;
    }
    if (!el) { return; }
    if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
      var r = el.getBoundingClientRect();
      try {
        el.contentWindow.postMessage({ __tvb: 1, cmd: 'clickAt', x: x - r.left - el.clientLeft, y: y - r.top - el.clientTop }, '*');
      } catch (e) {}
      return;
    }
    var target = el;
    if (target.closest) {
      var lab = target.closest('label');
      if (lab && lab.control) { target = lab.control; }
    }
    function fire(type, Ctor) {
      try {
        var ev = new (Ctor || window.MouseEvent)(type, { bubbles: true, cancelable: true, composed: true, view: window,
          clientX: x, clientY: y, screenX: x, screenY: y, button: 0,
          buttons: type.indexOf('down') >= 0 ? 1 : 0, pointerId: 1, pointerType: 'mouse', isPrimary: true });
        el.dispatchEvent(ev);
      } catch (e) {}
    }
    var PE = window.PointerEvent || window.MouseEvent;
    fire('pointerover', PE); fire('mouseover');
    fire('pointerdown', PE); fire('mousedown');
    try { if (target.focus) { target.focus({ preventScroll: true }); } } catch (e) {}
    fire('pointerup', PE); fire('mouseup');
    if (typeof el.click === 'function') { el.click(); } else { fire('click'); }
  }

  function handle(d, source) {
    var v = bestVideo();
    if (d.cmd === 'clickAt') { clickAt(d.x, d.y); return; }
    switch (d.cmd) {
      case 'pause':
        var all = document.querySelectorAll('video');
        for (var i = 0; i < all.length; i++) { try { all[i].pause(); } catch (e) {} }
        break;
      case 'toggle':
        if (v) { if (v.paused) { v.play(); } else { v.pause(); } }
        break;
      case 'seekBy':
        if (v) { v.currentTime = Math.max(0, v.currentTime + d.by); }
        break;
      case 'seekTo':
        if (v && d.t > 0) { v.currentTime = d.t; }
        break;
      case 'rate':
        if (v) { v.playbackRate = d.rate; }
        break;
      case 'fsEnter':
        if (v) {
          maximize(v, true);
          try { if (v.paused) { v.play(); } } catch (e) {}
          if (!isTop) { window.parent.postMessage({ __tvb: 1, cmd: 'fsFrame' }, '*'); }
        }
        break;
      case 'fsFrame':
        var fs = document.querySelectorAll('iframe,frame');
        for (var j = 0; j < fs.length; j++) {
          if (fs[j].contentWindow === source) {
            maximize(fs[j], false);
            if (!isTop) { window.parent.postMessage({ __tvb: 1, cmd: 'fsFrame' }, '*'); }
          }
        }
        return;
      case 'fsExit':
        restoreAll();
        break;
    }
    if (d.cmd !== 'fsFrame') { relay(d); }
    setTimeout(report, 300);
  }
  function relay(d) {
    var fs = document.querySelectorAll('iframe,frame');
    for (var i = 0; i < fs.length; i++) {
      try { fs[i].contentWindow.postMessage(d, '*'); } catch (e) {}
    }
  }
  window.addEventListener('message', function (e) {
    var d = e.data;
    if (!d || d.__tvb !== 1) { return; }
    handle(d, e.source);
  });
  window.__tvbCommand = function (d) { d.__tvb = 1; handle(d, null); return true; };

  document.addEventListener('play', function () { setTimeout(report, 200); }, true);
  document.addEventListener('pause', function () { setTimeout(report, 200); }, true);
  document.addEventListener('loadedmetadata', function () { setTimeout(report, 200); }, true);
  setInterval(report, 2000);
  setTimeout(report, 500);
})();
