import Foundation

/// 注入到网页里执行的 JavaScript。
/// 传进来的坐标是屏幕上的点（point），脚本里用 innerWidth 换算成网页的 CSS 像素。
enum PageScripts {
    /// 把 Swift 字符串安全地变成 JS 字符串字面量。
    static func jsString(_ s: String) -> String {
        if let data = try? JSONEncoder().encode(s), let literal = String(data: data, encoding: .utf8) {
            return literal
        }
        return "\"\""
    }

    private static func num(_ v: CGFloat) -> String {
        String(format: "%.2f", Double(v))
    }

    /// 公共部分：找出坐标下的元素（会进入同源 iframe 和 shadow DOM）。
    private static let resolver = """
    function __tvbResolve(px, py, viewWidth, forward) {
      var scale = window.innerWidth / viewWidth;
      var x = px * scale, y = py * scale;
      var doc = document, el = doc.elementFromPoint(x, y);
      var guard = 0;
      while (el && guard++ < 20) {
        if (el.shadowRoot && el.shadowRoot.elementFromPoint) {
          var inner = el.shadowRoot.elementFromPoint(x, y);
          if (inner && inner !== el) { el = inner; continue; }
        }
        if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
          try {
            var r = el.getBoundingClientRect();
            var d = el.contentDocument;
            if (d) {
              x -= r.left + el.clientLeft; y -= r.top + el.clientTop;
              var inner2 = d.elementFromPoint(x, y);
              if (inner2) { doc = d; el = inner2; continue; }
            }
          } catch (e) {}
          // 其他网站的框架（比如 Cloudflare 验证框、外站播放器）：浏览器不让直接操作，
          // 把坐标转交给注入在那个框架里的脚本，由它在框架内部点击
          if (forward) {
            var fr = el.getBoundingClientRect();
            try {
              el.contentWindow.postMessage({ __tvb: 1, cmd: 'clickAt', x: x - fr.left - el.clientLeft, y: y - fr.top - el.clientTop }, '*');
              return { el: el, x: x, y: y, doc: doc, forwarded: true };
            } catch (e) {}
          }
        }
        break;
      }
      return { el: el, x: x, y: y, doc: doc };
    }
    """

    /// 在光标处点击。返回 JSON：
    /// {kind:"click"} / {kind:"none"} / {kind:"text", value, label, secure, multiline, inputType} / {kind:"select", options, selected}
    static func click(x: CGFloat, y: CGFloat, viewWidth: CGFloat) -> String {
        """
        (function(){
          \(resolver)
          var hit = __tvbResolve(\(num(x)), \(num(y)), \(num(viewWidth)), true);
          if (hit.forwarded) { return JSON.stringify({kind: 'forwarded'}); }
          var el = hit.el;
          if (!el) { return JSON.stringify({kind: 'none'}); }
          var win = (hit.doc.defaultView || window);

          function labelFor(t) {
            var s = t.getAttribute && (t.getAttribute('aria-label') || t.getAttribute('placeholder') || t.getAttribute('title') || t.getAttribute('name'));
            if (!s && t.labels && t.labels.length) { s = t.labels[0].innerText; }
            return (s || '').trim().slice(0, 80);
          }

          var target = el;
          if (target.closest) {
            var lab = target.closest('label');
            if (lab && lab.control) { target = lab.control; }
          }
          var editable = target.closest ? target.closest('input, textarea, select, [contenteditable]') : null;
          var textTypes = ['', 'text', 'search', 'email', 'url', 'tel', 'password', 'number'];

          if (editable && !editable.disabled) {
            var tag = editable.tagName.toLowerCase();
            if (tag === 'select') {
              win.__tvbEl = editable;
              var opts = [];
              for (var i = 0; i < editable.options.length; i++) { opts.push((editable.options[i].text || '').trim()); }
              return JSON.stringify({kind: 'select', options: opts, selected: editable.selectedIndex, label: labelFor(editable)});
            }
            var type = (editable.getAttribute('type') || '').toLowerCase();
            var isText = (tag === 'textarea') || (tag === 'input' && textTypes.indexOf(type) >= 0) || (tag !== 'input' && editable.isContentEditable);
            if (isText && !editable.readOnly) {
              win.__tvbEl = editable;
              window.__tvbEl = editable;
              try { editable.focus({preventScroll: true}); } catch (e) {}
              var value = ('value' in editable && tag !== 'div') ? editable.value : editable.innerText;
              return JSON.stringify({kind: 'text', value: value || '', label: labelFor(editable),
                secure: type === 'password', multiline: tag === 'textarea' || tag !== 'input', inputType: type});
            }
          }

          function fire(type, Ctor) {
            try {
              var ev = new (Ctor || win.MouseEvent)(type, {bubbles: true, cancelable: true, composed: true, view: win,
                clientX: hit.x, clientY: hit.y, screenX: hit.x, screenY: hit.y, button: 0,
                buttons: type.indexOf('down') >= 0 ? 1 : 0, pointerId: 1, pointerType: 'mouse', isPrimary: true});
              return el.dispatchEvent(ev);
            } catch (e) { return true; }
          }
          var PE = win.PointerEvent || win.MouseEvent;
          fire('pointerover', PE); fire('mouseover');
          fire('pointerdown', PE); fire('mousedown');
          try { if (target.focus) { target.focus({preventScroll: true}); } } catch (e) {}
          fire('pointerup', PE); fire('mouseup');
          if (typeof el.click === 'function') { el.click(); } else { fire('click'); }
          return JSON.stringify({kind: 'click'});
        })()
        """
    }

    /// 把文字填进上一次点到的输入框；submit 为 true 时再模拟按回车 / 提交表单。
    static func setText(_ text: String, submit: Bool) -> String {
        """
        (function(v, submit){
          var el = window.__tvbEl;
          if (!el) {
            var frames = document.querySelectorAll('iframe');
            for (var i = 0; i < frames.length && !el; i++) {
              try { el = frames[i].contentWindow.__tvbEl; } catch (e) {}
            }
          }
          if (!el) { return false; }
          var win = (el.ownerDocument && el.ownerDocument.defaultView) || window;
          try { el.focus({preventScroll: true}); } catch (e) {}
          var tag = el.tagName.toLowerCase();
          if (tag === 'input' || tag === 'textarea') {
            var proto = tag === 'textarea' ? win.HTMLTextAreaElement.prototype : win.HTMLInputElement.prototype;
            var desc = Object.getOwnPropertyDescriptor(proto, 'value');
            if (desc && desc.set) { desc.set.call(el, v); } else { el.value = v; }
          } else {
            el.innerText = v;
          }
          el.dispatchEvent(new win.Event('input', {bubbles: true}));
          el.dispatchEvent(new win.Event('change', {bubbles: true}));
          if (submit) {
            var o = {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true};
            var notPrevented = el.dispatchEvent(new win.KeyboardEvent('keydown', o));
            el.dispatchEvent(new win.KeyboardEvent('keypress', o));
            el.dispatchEvent(new win.KeyboardEvent('keyup', o));
            if (notPrevented && el.form) {
              if (el.form.requestSubmit) { el.form.requestSubmit(); } else { el.form.submit(); }
            }
          }
          return true;
        })(\(jsString(text)), \(submit ? "true" : "false"))
        """
    }

    /// 选中下拉框的第 index 项。
    static func selectOption(_ index: Int) -> String {
        """
        (function(i){
          var el = window.__tvbEl;
          if (!el) {
            var frames = document.querySelectorAll('iframe');
            for (var k = 0; k < frames.length && !el; k++) {
              try { el = frames[k].contentWindow.__tvbEl; } catch (e) {}
            }
          }
          if (!el || el.tagName.toLowerCase() !== 'select') { return false; }
          var win = el.ownerDocument.defaultView || window;
          el.selectedIndex = i;
          el.dispatchEvent(new win.Event('input', {bubbles: true}));
          el.dispatchEvent(new win.Event('change', {bubbles: true}));
          return true;
        })(\(index))
        """
    }

    /// 当整页不能滚动时（很多网站把内容放在内部的滚动区域里），滚动光标下最近的可滚动元素。
    static func scrollInner(x: CGFloat, y: CGFloat, viewWidth: CGFloat, dx: CGFloat, dy: CGFloat) -> String {
        """
        (function(){
          \(resolver)
          var hit = __tvbResolve(\(num(x)), \(num(y)), \(num(viewWidth)), false);
          var scale = window.innerWidth / \(num(viewWidth));
          var dx = \(num(dx)) * scale, dy = \(num(dy)) * scale;
          var el = hit.el;
          while (el && el.nodeType === 1) {
            var st = getComputedStyle(el);
            var canY = dy !== 0 && /(auto|scroll|overlay)/.test(st.overflowY) && el.scrollHeight > el.clientHeight + 1;
            var canX = dx !== 0 && /(auto|scroll|overlay)/.test(st.overflowX) && el.scrollWidth > el.clientWidth + 1;
            if (canY || canX) {
              var beforeTop = el.scrollTop, beforeLeft = el.scrollLeft;
              el.scrollBy(dx, dy);
              if (el.scrollTop !== beforeTop || el.scrollLeft !== beforeLeft) { return true; }
            }
            el = el.parentElement || (el.getRootNode && el.getRootNode().host) || null;
          }
          var w = hit.doc.defaultView || window;
          w.scrollBy(dx, dy);
          return false;
        })()
        """
    }
}
