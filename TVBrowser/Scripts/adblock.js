(function () {
  if (window.__tvbAdblock) { return; }
  window.__tvbAdblock = true;
  // 常见广告联盟（谷歌等）的广告框
  var NETWORK_ADS = 'ins.adsbygoogle,iframe[id^="google_ads"],iframe[src*="googlesyndication"],iframe[src*="doubleclick"],div[id^="div-gpt-ad"]';
  var SITES = {
    'olehdtv.com': {
      css: '#notice_fixed,.notice-fixed,.imgBox,.L4A,.A4R,#adWrap,.ads,.right_ads,.loading-container a[href^="http"],' + NETWORK_ADS + '{display:none!important}' +
           'html,body{overflow:auto!important}',
      friends: ['olelive.com', 'olevod.com', 'oulehdtv.tv', 'olehdtv.com']
    },
    // 自检用的本地测试页
    'selftest.local': { css: '', friends: [] },
    'kubb.tv': {
      css: 'a[href*="ppt.kubb.tv/c/"],' + NETWORK_ADS + '{display:none!important}',
      adHref: /ppt\.kubb\.tv\/c\//,
      friends: ['kubb.tv', 'wuye.tv']
    }
  };
  function baseOf(host) {
    var p = (host || '').toLowerCase().split('.');
    return p.length <= 2 ? p.join('.') : p.slice(-2).join('.');
  }
  var self = baseOf(location.hostname);
  var site = SITES[self] || null;
  // 只在已适配的网站上隐藏广告位；其他网站只由 App 拦截自动弹出的广告窗口，避免误伤正常的外站链接
  if (!site) { return; }
  var friends = {};
  friends[self] = true;
  if (site) { site.friends.forEach(function (f) { friends[f] = true; }); }
  function isExternal(a) {
    var href = a.getAttribute('href') || '';
    if (!/^(https?:)?\/\//i.test(href)) { return false; }
    try { return !friends[baseOf(new URL(a.href).hostname)]; } catch (e) { return false; }
  }
  function addStyle(css) {
    var s = document.createElement('style');
    s.setAttribute('data-tvb', 'adblock');
    s.textContent = css;
    (document.head || document.documentElement).appendChild(s);
  }
  if (site && site.css) { addStyle(site.css); }

  var hiddenCount = 0;
  function hide(el) {
    if (!el || el.__tvbHidden) { return; }
    el.__tvbHidden = true;
    el.style.setProperty('display', 'none', 'important');
    hiddenCount++;
  }
  function looksLikeAd(a) {
    var r = a.getBoundingClientRect();
    if (a.querySelector('img,picture,video,canvas')) { return true; }
    var bg = getComputedStyle(a).backgroundImage;
    if (bg && bg !== 'none') { return true; }
    return r.width >= 300 && r.height >= 60;
  }
  var pendingSlides = [];
  function swiperOf(el) {
    while (el) {
      if (el.swiper && el.swiper.removeSlide) { return el.swiper; }
      el = el.parentElement;
    }
    return null;
  }
  // 轮播图里的广告：用轮播组件自己的接口删掉（循环模式下复制出来的轮播项会一起更新），不留空白页
  function flushSlides() {
    var groups = [];
    pendingSlides.forEach(function (slide) {
      var sw = swiperOf(slide);
      if (!sw || !sw.removeSlide) { hide(slide); return; }
      var real = slide.getAttribute('data-swiper-slide-index');
      var idx = real !== null ? parseInt(real, 10) : Array.prototype.indexOf.call(sw.slides, slide);
      var g = null;
      for (var i = 0; i < groups.length; i++) { if (groups[i].sw === sw) { g = groups[i]; } }
      if (!g) { g = { sw: sw, idx: [], els: [] }; groups.push(g); }
      if (idx >= 0 && g.idx.indexOf(idx) < 0) { g.idx.push(idx); }
      g.els.push(slide);
    });
    groups.forEach(function (g) {
      try { g.sw.removeSlide(g.idx); hiddenCount += g.idx.length; } catch (e) { g.els.forEach(hide); }
    });
    pendingSlides = [];
  }
  function collapseParents(el) {
    var p = el.parentElement, depth = 0;
    while (p && p !== document.body && depth < 3) {
      var kids = p.children, visible = 0;
      for (var i = 0; i < kids.length; i++) {
        if (!kids[i].__tvbHidden && getComputedStyle(kids[i]).display !== 'none') { visible++; }
      }
      if (visible > 0 || (p.innerText || '').trim().length > 0) { break; }
      hide(p);
      p = p.parentElement;
      depth++;
    }
  }
  function scan() {
    var links = document.querySelectorAll('a[href]');
    for (var i = 0; i < links.length; i++) {
      var a = links[i];
      if (a.__tvbChecked) { continue; }
      var known = site && site.adHref && site.adHref.test(a.href);
      if (!known && !isExternal(a)) { a.__tvbChecked = true; continue; }
      if (!known && !looksLikeAd(a)) { continue; }
      a.__tvbChecked = true;
      var slide = a.closest('.swiper-slide');
      if (slide) { pendingSlides.push(slide); continue; }
      hide(a);
      collapseParents(a);
    }
    if (pendingSlides.length) { flushSlides(); }
    window.__tvbAdsHidden = hiddenCount;
  }
  function start() {
    scan();
    var timer = null;
    new MutationObserver(function () {
      if (timer) { return; }
      timer = setTimeout(function () { timer = null; scan(); }, 300);
    }).observe(document.documentElement, { childList: true, subtree: true });
    setTimeout(scan, 1500);
    setTimeout(scan, 4000);
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
