/**
 * JavaScript injected into every HTML book page.
 *
 * Paged mode uses CSS multi-column layout: on a tablet the same passage can be
 * shown as one comfortable column in portrait or two columns in landscape,
 * without turning the book into a phone page stretched across the screen.
 * Position is reported as a character fraction (the phone's metric), not as a
 * pixel scroll fraction.
 */
export const READER_SCRIPT: string = `
(function () {
  var config = window.__EASYREAD__ || {};
  var state = {
    mode: config.mode || 'paged',
    columns: config.columns || 1,
    page: 0,
    pages: 1,
    step: 0,
    gap: 28,
    charMap: [],
    nodeMap: new Map(),
    totalChars: 0,
    flatText: '',
    marks: [],
    markIndex: -1,
    suppressReport: false,
    scrollTimer: 0,
    wheelTime: 0,
    lastReported: -1,
    touchX: 0,
    touchY: 0,
    touchTime: 0,
    viewWidth: 0,
    viewHeight: 0,
    booted: false,
    windowRequested: false,
    scrollSettle: 0,
    lastScrollTop: 0
  };
  var frame = null;
  var viewport = null;
  var paged = null;

  function post(payload) {
    try {
      if (window.easyread && window.easyread.postMessage) {
        window.easyread.postMessage(JSON.stringify(payload));
      }
    } catch (error) {
    }
  }

  function clamp(value, min, max) {
    return Math.min(Math.max(value, min), max);
  }

  /*
   * A long book is delivered as a chapter-aligned window. Every position the
   * page reports to ArkTS is a whole-book fraction; internally the page keeps
   * working with fractions of its own window so page turns stay local.
   */
  function windowBase() {
    return typeof config.windowBase === 'number' ? config.windowBase : 0;
  }

  function windowSpan() {
    var span = typeof config.windowSpan === 'number' ? config.windowSpan : 1;
    return span > 0.000001 ? span : 1;
  }

  function globalProgress() {
    return clamp(windowBase() + textProgressAtPage() * windowSpan(), 0, 1);
  }

  function localProgressOf(global) {
    return clamp((global - windowBase()) / windowSpan(), 0, 1);
  }

  function initialLocalProgress() {
    var progress = typeof config.textProgress === 'number' ? config.textProgress : 0;
    if (progress <= 0 && typeof config.progress === 'number' && config.progress > 0) {
      progress = config.progress;
    }
    return localProgressOf(progress);
  }

  function hasNextWindow() {
    return windowBase() + windowSpan() < 0.999999;
  }

  function hasPreviousWindow() {
    return windowBase() > 0.000001;
  }

  function requestWindow(direction) {
    if (state.windowRequested) {
      return;
    }
    state.windowRequested = true;
    var progress = direction === 'next'
      ? Math.min(1, windowBase() + windowSpan())
      : Math.max(0, windowBase() - 0.000001);
    post({ type: 'diag', message: 'request window ' + direction + ' scrollTop=' +
      Math.round(viewport.scrollTop) + ' max=' +
      Math.round(viewport.scrollHeight - viewport.clientHeight) });
    post({ type: 'window', direction: direction, progress: progress });
  }

  function requestWindowAt(progress) {
    if (state.windowRequested) {
      return;
    }
    state.windowRequested = true;
    post({ type: 'window', direction: 'start', progress: clamp(progress, 0, 1) });
  }

  function debounce(fn, delay) {
    var timer = 0;
    return function () {
      clearTimeout(timer);
      timer = setTimeout(fn, delay);
    };
  }

  function cssNumber(name, fallback) {
    var value = getComputedStyle(document.documentElement).getPropertyValue(name);
    var parsed = parseFloat(value);
    return isNaN(parsed) ? fallback : parsed;
  }

  function applyTypography() {
    var root = document.documentElement;
    root.style.setProperty('--er-font-size', (config.fontSize || 20) + 'px');
    root.style.setProperty('--er-line-height', String(config.lineHeight || 1.8));
    root.style.setProperty('--er-margin', String(config.margin || 0.08));
    root.style.setProperty('--er-gap', state.gap + 'px');
    root.setAttribute('data-theme', config.theme || 'paper');
    root.setAttribute('data-font', config.fontFamily || 'serif');
  }

  function measureFrame() {
    // Measure the document viewport, not #er-viewport: the latter already
    // excludes the page margin applied below. Deriving the margin from an
    // already-inset width made every layout pass shrink the margin a little
    // further (566 -> 584 -> ...) and re-flow the text for no reason.
    var width = document.documentElement.clientWidth;
    var height = document.documentElement.clientHeight;
    var margin = config.margin || 0.08;
    var padX = Math.max(20, Math.round(width * margin));
    // The top toolbar and the progress bar are overlays. Their height is
    // reserved inside the page so toggling them never resizes the WebView
    // (which used to leave a half-cut page behind).
    var padTop = Math.max(58, Math.round(height * 0.07));
    var padBottom = Math.max(48, Math.round(height * 0.06));
    frame.style.padding = padTop + 'px ' + padX + 'px ' + padBottom + 'px';
    // Applying the page margin shrinks the viewport. Text is typeset into the
    // size after padding, so that is the size to remember: recording the
    // pre-padding size made the self-inflicted change look like a window
    // resize and forced a second full typeset right after the first one.
    var innerWidth = viewport.clientWidth;
    var innerHeight = viewport.clientHeight;
    state.viewWidth = innerWidth;
    state.viewHeight = innerHeight;
    return { width: innerWidth, height: innerHeight };
  }

  function pickColumns(width) {
    if (state.mode !== 'paged') {
      return 1;
    }
    if (config.columns === 'two') {
      return width >= 620 ? 2 : 1;
    }
    if (config.columns === 'one') {
      return 1;
    }
    return width >= 760 ? 2 : 1;
  }

  function buildTextMap() {
    state.charMap = [];
    state.nodeMap = new Map();
    var total = 0;
    var flat = '';
    var walker = document.createTreeWalker(paged, NodeFilter.SHOW_TEXT, null);
    var node = walker.nextNode();
    while (node) {
      var text = node.nodeValue || '';
      if (text.length > 0) {
        var entry = { node: node, start: total, length: text.length };
        state.charMap.push(entry);
        state.nodeMap.set(node, entry);
        flat += text;
        total += text.length;
      }
      node = walker.nextNode();
    }
    state.totalChars = total;
    state.flatText = flat;
  }

  function revealPage() {
    if (!state.booted) {
      state.booted = true;
      paged.style.visibility = 'visible';
    }
  }

  function currentOffset() {
    if (state.totalChars <= 0) {
      return 0;
    }
    var rect = viewport.getBoundingClientRect();
    if (state.mode === 'paged') {
      var pagedOffset = offsetAtPoint(rect.left + 12, rect.top + 12);
      if (pagedOffset < 0 || (pagedOffset === 0 && state.page > 0)) {
        pagedOffset = Math.floor(state.page / Math.max(1, state.pages) * state.totalChars);
      }
      return clamp(pagedOffset, 0, Math.max(0, state.totalChars - 1));
    }
    var offset = offsetAtPoint(rect.left + 2, rect.top + 2);
    if (offset < 0) {
      var max = Math.max(1, viewport.scrollHeight - viewport.clientHeight);
      return Math.floor(clamp(viewport.scrollTop / max, 0, 1) * state.totalChars);
    }
    return clamp(offset, 0, Math.max(0, state.totalChars - 1));
  }

  function entryFor(offset) {
    var map = state.charMap;
    if (map.length === 0) {
      return null;
    }
    var low = 0;
    var high = map.length - 1;
    while (low <= high) {
      var middle = Math.floor((low + high) / 2);
      var item = map[middle];
      if (offset < item.start) {
        high = middle - 1;
      } else if (offset >= item.start + item.length) {
        low = middle + 1;
      } else {
        return item;
      }
    }
    return map[map.length - 1];
  }

  function offsetAtPoint(x, y) {
    if (!document.caretRangeFromPoint) {
      return -1;
    }
    var range = document.caretRangeFromPoint(x, y);
    if (!range || !range.startContainer || range.startContainer.nodeType !== 3) {
      return -1;
    }
    var entry = state.nodeMap.get(range.startContainer);
    if (entry) {
      return entry.start + range.startOffset;
    }
    return -1;
  }

  function rectForOffset(offset) {
    var entry = entryFor(clamp(offset, 0, Math.max(0, state.totalChars - 1)));
    if (!entry) {
      return null;
    }
    var local = clamp(offset - entry.start, 0, Math.max(0, entry.length - 1));
    var range = document.createRange();
    range.setStart(entry.node, local);
    range.setEnd(entry.node, Math.min(entry.length, local + 1));
    return range.getBoundingClientRect();
  }

  function pageForOffset(offset) {
    if (state.mode !== 'paged') {
      return 0;
    }
    var rect = rectForOffset(offset);
    if (!rect) {
      var ratio = state.totalChars > 0 ? offset / state.totalChars : 0;
      return clamp(Math.round(ratio * Math.max(0, state.pages - 1)), 0, Math.max(0, state.pages - 1));
    }
    var base = paged.getBoundingClientRect();
    var x = rect.left - base.left;
    return clamp(Math.floor(x / Math.max(1, state.step)), 0, Math.max(0, state.pages - 1));
  }

  function textProgressAtPage() {
    if (state.totalChars <= 0) {
      return 0;
    }
    return clamp(currentOffset() / state.totalChars, 0, 1);
  }

  function applyTransform() {
    // A sliding transition over a full-book multi-column layer is what made
    // page turns feel heavy on the tablet; an instant page is much smoother.
    paged.style.transition = 'none';
    paged.style.transform = 'translateX(' + (-state.page * state.step) + 'px)';
  }

  function layout(keepPosition) {
    if (state.mode !== 'paged') {
      layoutScroll(keepPosition);
      return;
    }
    var startedAt = performance.now();
    var previousProgress = keepPosition ? textProgressAtPage() : -1;
    if (keepPosition && previousProgress <= 0 && state.page > 0) {
      previousProgress = state.page / Math.max(1, state.pages);
    }
    paged.style.transform = 'translateX(0)';
    var size = measureFrame();
    if (size.width <= 0 || size.height <= 0) {
      return;
    }
    state.columns = pickColumns(size.width);
    paged.style.columnCount = String(state.columns);
    paged.style.columnGap = state.gap + 'px';
    paged.style.height = size.height + 'px';
    paged.style.width = size.width + 'px';
    paged.scrollWidth;
    var laidOutAt = performance.now();
    buildTextMap();
    var mappedAt = performance.now();
    state.step = size.width + state.gap;
    var totalWidth = paged.scrollWidth;
    state.pages = Math.max(1, Math.ceil((totalWidth + state.gap) / state.step));
    post({ type: 'diag', message: 'layout ' + size.width + 'x' + size.height + ' pages=' + state.pages +
      ' chars=' + state.totalChars + ' width=' + totalWidth + ' cols=' + state.columns +
      ' base=' + windowBase() + ' span=' + windowSpan() +
      ' format=' + Math.round(laidOutAt - startedAt) + ' map=' + Math.round(mappedAt - laidOutAt) +
      ' took=' + Math.round(performance.now() - startedAt) + 'ms at ' + Math.round(performance.now()) + 'ms' });
    var target = 0;
    if (previousProgress >= 0) {
      target = pageForOffset(Math.floor(previousProgress * state.totalChars));
    } else {
      target = initialPage();
    }
    state.page = clamp(target, 0, state.pages - 1);
    applyTransform();
    revealPage();
    post({ type: 'layout', page: state.page + 1, pages: state.pages });
    reportPosition(true);
  }

  function initialPage() {
    var localTarget = initialLocalProgress();
    if (config.locatorText && config.locatorText.length > 0) {
      var offset = findTextOffset(config.locatorText, localTarget);
      if (offset >= 0) {
        return pageForOffset(offset);
      }
    }
    if (localTarget <= 0) {
      return 0;
    }
    return pageForOffset(Math.floor(localTarget * state.totalChars));
  }

  function findTextOffset(needle, nearProgress) {
    if (!needle || needle.length === 0) {
      return -1;
    }
    var target = nearProgress * state.totalChars;
    var best = -1;
    var bestDistance = Infinity;
    for (var i = 0; i < state.charMap.length; i++) {
      var item = state.charMap[i];
      var text = item.node.nodeValue || '';
      var from = 0;
      while (from < text.length) {
        var index = text.indexOf(needle, from);
        if (index < 0) {
          break;
        }
        var absolute = item.start + index;
        var distance = Math.abs(absolute - target);
        if (distance < bestDistance) {
          best = absolute;
          bestDistance = distance;
        }
        from = index + Math.max(1, needle.length);
      }
    }
    return best;
  }

  function layoutScroll(keepPosition) {
    var startedAt = performance.now();
    var previousProgress = keepPosition ? scrollProgress() : -1;
    paged.style.transform = 'none';
    paged.style.columnCount = '1';
    paged.style.columnGap = '0px';
    paged.style.height = 'auto';
    paged.style.width = 'auto';
    measureFrame();
    viewport.style.overflowY = 'auto';
    viewport.style.overflowX = 'hidden';
    buildTextMap();
    revealPage();
    var finish = function () {
      // Arm the guard after the programmatic scrolls below: a re-layout can
      // take longer than the guard itself, and scroll events from restoring
      // the position must not be mistaken for the reader reaching an edge.
      state.scrollSettle = Date.now() + 700;
      post({ type: 'diag', message: 'layoutScroll chars=' + state.totalChars +
        ' height=' + viewport.scrollHeight + ' base=' + windowBase() +
        ' span=' + windowSpan() + ' took=' +
        Math.round(performance.now() - startedAt) + 'ms' });
      reportPosition(true);
    };
    if (previousProgress >= 0) {
      scrollToOffset(Math.floor(previousProgress * state.totalChars));
      finish();
      return;
    }
    var localTarget = initialLocalProgress();
    if (config.locatorText) {
      var offset = findTextOffset(config.locatorText, localTarget);
      if (offset >= 0) {
        scrollToOffset(offset);
        finish();
        return;
      }
    }
    if (localTarget > 0) {
      scrollToOffset(Math.floor(localTarget * state.totalChars));
    }
    finish();
  }

  function scrollToOffset(offset) {
    var rect = rectForOffset(offset);
    if (!rect) {
      return;
    }
    var top = viewport.getBoundingClientRect().top;
    viewport.scrollTop += rect.top - top - 8;
  }

  function scrollProgress() {
    if (state.totalChars <= 0) {
      return 0;
    }
    return clamp(currentOffset() / state.totalChars, 0, 1);
  }

  function pageInfo() {
    return { page: state.page + 1, pages: state.pages };
  }

  function reportPosition(force) {
    if (state.suppressReport && !force) {
      return;
    }
    var progress = globalProgress();
    var info = pageInfo();
    if (!force && Math.abs(progress - state.lastReported) < 0.00002) {
      return;
    }
    state.lastReported = progress;
    // The locator and the longer snippet both start at the same character;
    // sampling the caret once keeps a page turn cheap.
    var offset = currentOffset();
    var locator = state.flatText.substring(offset, offset + 64)
      .replace(/^[\\s\\u3000]+/, '').substring(0, 12);
    var snippet = state.flatText.substring(offset, offset + 80)
      .replace(/\\s+/g, ' ').trim().substring(0, 60);
    post({
      type: 'position',
      progress: progress,
      page: info.page,
      pages: info.pages,
      mode: state.mode,
      locator: locator,
      snippet: snippet
    });
  }

  function goToPage(page) {
    if (state.mode !== 'paged') {
      return;
    }
    state.page = clamp(page, 0, state.pages - 1);
    applyTransform();
    post({ type: 'layout', page: state.page + 1, pages: state.pages });
    reportPosition(true);
  }

  function nextPage() {
    if (state.mode !== 'paged') {
      var max = viewport.scrollHeight - viewport.clientHeight;
      if (max > 0 && viewport.scrollTop >= max - 24) {
        if (hasNextWindow()) {
          requestWindow('next');
        }
        return;
      }
      viewport.scrollTop += viewport.clientHeight * 0.9;
      return;
    }
    if (state.page < state.pages - 1) {
      goToPage(state.page + 1);
      return;
    }
    if (hasNextWindow()) {
      requestWindow('next');
    }
  }

  function previousPage() {
    if (state.mode !== 'paged') {
      if (viewport.scrollTop <= 4) {
        if (hasPreviousWindow()) {
          requestWindow('prev');
        }
        return;
      }
      viewport.scrollTop -= viewport.clientHeight * 0.9;
      return;
    }
    if (state.page > 0) {
      goToPage(state.page - 1);
      return;
    }
    if (hasPreviousWindow()) {
      requestWindow('prev');
    }
  }

  function goToAnchor(anchorId, locatorText, progress) {
    var offset = -1;
    if (locatorText && locatorText.length > 0) {
      offset = findTextOffset(locatorText, progress || 0);
    }
    if (offset < 0 && anchorId) {
      var element = document.getElementById(anchorId);
      if (element) {
        var range = document.createRange();
        range.setStartBefore(element);
        range.setEndBefore(element);
        var rect = range.getBoundingClientRect();
        if (state.mode === 'paged') {
          var base = paged.getBoundingClientRect();
          var page = clamp(Math.floor((rect.left - base.left) / Math.max(1, state.step)), 0, state.pages - 1);
          goToPage(page);
          return;
        }
        element.scrollIntoView({ block: 'start' });
        reportPosition(true);
        return;
      }
    }
    if (offset < 0 && progress > 0) {
      offset = Math.floor(progress * state.totalChars);
    }
    if (offset < 0) {
      return;
    }
    if (state.mode === 'paged') {
      goToPage(pageForOffset(offset));
    } else {
      scrollToOffset(offset);
      reportPosition(true);
    }
  }

  function clearMarks() {
    var marks = paged.querySelectorAll('mark.er-find');
    for (var i = marks.length - 1; i >= 0; i--) {
      var mark = marks[i];
      var parent = mark.parentNode;
      if (parent) {
        parent.replaceChild(document.createTextNode(mark.textContent || ''), mark);
        parent.normalize();
      }
    }
    state.marks = [];
    state.markIndex = -1;
    // normalize() merges and replaces text nodes, so every node reference in
    // charMap is stale after this point. Rebuild it here, otherwise closing
    // search leaves progress/snippets reading a detached text map.
    buildTextMap();
  }

  function find(query) {
    clearMarks();
    if (!query || query.length === 0) {
      post({ type: 'search', count: 0, index: -1 });
      return;
    }
    var lowered = query.toLowerCase();
    var nodes = [];
    for (var i = 0; i < state.charMap.length; i++) {
      nodes.push(state.charMap[i]);
    }
    var found = 0;
    for (var n = 0; n < nodes.length && found < 300; n++) {
      var node = nodes[n].node;
      var text = node.nodeValue || '';
      var loweredText = text.toLowerCase();
      var index = loweredText.indexOf(lowered);
      if (index < 0) {
        continue;
      }
      var fragment = document.createDocumentFragment();
      var cursor = 0;
      while (index >= 0 && found < 300) {
        if (index > cursor) {
          fragment.appendChild(document.createTextNode(text.substring(cursor, index)));
        }
        var mark = document.createElement('mark');
        mark.className = 'er-find';
        mark.appendChild(document.createTextNode(text.substring(index, index + query.length)));
        fragment.appendChild(mark);
        found += 1;
        cursor = index + query.length;
        index = loweredText.indexOf(lowered, cursor);
      }
      if (cursor < text.length) {
        fragment.appendChild(document.createTextNode(text.substring(cursor)));
      }
      if (node.parentNode) {
        node.parentNode.replaceChild(fragment, node);
      }
    }
    state.marks = Array.prototype.slice.call(paged.querySelectorAll('mark.er-find'));
    if (state.marks.length === 0) {
      post({ type: 'search', count: 0, index: -1 });
      return;
    }
    buildTextMap();
    jumpToMark(0);
    post({ type: 'search', count: state.marks.length, index: 1 });
  }

  function offsetForNode(node, localOffset) {
    var entry = state.nodeMap.get(node);
    return entry ? entry.start + localOffset : -1;
  }

  function jumpToMark(index) {
    if (state.marks.length === 0) {
      return;
    }
    state.markIndex = ((index % state.marks.length) + state.marks.length) % state.marks.length;
    for (var i = 0; i < state.marks.length; i++) {
      if (i === state.markIndex) {
        state.marks[i].classList.add('er-find-current');
      } else {
        state.marks[i].classList.remove('er-find-current');
      }
    }
    var mark = state.marks[state.markIndex];
    var textNode = mark.firstChild;
    if (!textNode) {
      return;
    }
    var offset = offsetForNode(textNode, 0);
    if (offset < 0) {
      return;
    }
    if (state.mode === 'paged') {
      goToPage(pageForOffset(offset));
    } else {
      scrollToOffset(offset);
      reportPosition(true);
    }
  }

  function findNext() {
    if (state.marks.length === 0) {
      return;
    }
    jumpToMark(state.markIndex + 1);
    post({ type: 'search', count: state.marks.length, index: state.markIndex + 1 });
  }

  function findPrevious() {
    if (state.marks.length === 0) {
      return;
    }
    jumpToMark(state.markIndex - 1);
    post({ type: 'search', count: state.marks.length, index: state.markIndex + 1 });
  }

  function selectionText() {
    var selection = window.getSelection();
    return selection ? String(selection.toString() || '') : '';
  }

  function clearSelection() {
    var selection = window.getSelection();
    if (selection) {
      selection.removeAllRanges();
    }
  }

  function onKey(event) {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey) {
      return;
    }
    if (event.key === 'ArrowRight' || event.key === 'PageDown' || event.key === ' ') {
      nextPage();
      event.preventDefault();
    } else if (event.key === 'ArrowLeft' || event.key === 'PageUp') {
      previousPage();
      event.preventDefault();
    } else if (event.key === 'Home') {
      goToPage(0);
      event.preventDefault();
    } else if (event.key === 'End') {
      goToPage(state.pages - 1);
      event.preventDefault();
    }
  }

  function bindTouch() {
    paged.addEventListener('click', function (event) {
      var target = event.target;
      var anchor = target && target.closest ? target.closest('a') : null;
      if (anchor) {
        event.preventDefault();
        event.stopPropagation();
      }
    }, true);
    viewport.addEventListener('touchstart', function (event) {
      if (event.touches.length !== 1) {
        return;
      }
      state.touchX = event.touches[0].clientX;
      state.touchY = event.touches[0].clientY;
      state.touchTime = Date.now();
    }, { passive: true });
    viewport.addEventListener('touchend', function (event) {
      if (event.changedTouches.length !== 1) {
        return;
      }
      var target = event.target;
      if (target && target.closest && target.closest('a')) {
        return;
      }
      var dx = event.changedTouches[0].clientX - state.touchX;
      var dy = event.changedTouches[0].clientY - state.touchY;
      var elapsed = Date.now() - state.touchTime;
      var selection = selectionText();
      if (selection.length > 0) {
        return;
      }
      if (state.mode === 'paged' && Math.abs(dx) > 48 && Math.abs(dx) > Math.abs(dy) * 1.4) {
        if (dx < 0) {
          nextPage();
        } else {
          previousPage();
        }
        return;
      }
      if (state.mode === 'scroll' && Math.abs(dy) > 60 && Math.abs(dy) > Math.abs(dx) * 1.2) {
        // Pulling past the top or pushing past the bottom continues into the
        // neighbouring window. The scroll listener alone would miss these
        // gestures because the browser does not move (and fires no scroll
        // event) once the content is already at the edge.
        var max = viewport.scrollHeight - viewport.clientHeight;
        if (dy > 0 && viewport.scrollTop <= 4) {
          if (hasPreviousWindow()) {
            requestWindow('prev');
          }
          return;
        }
        if (dy < 0 && max > 0 && viewport.scrollTop >= max - 4) {
          if (hasNextWindow()) {
            requestWindow('next');
          }
          return;
        }
      }
      if (Math.abs(dx) < 12 && Math.abs(dy) < 12 && elapsed < 350) {
        var rect = viewport.getBoundingClientRect();
        var localY = event.changedTouches[0].clientY - rect.top;
        // Taps under the overlaid toolbar or progress bar belong to those
        // controls; everything else is a request to show/hide the chrome.
        if (localY < 100 || localY > viewport.clientHeight - 56) {
          return;
        }
        post({ type: 'tap' });
      }
    }, { passive: true });
    viewport.addEventListener('scroll', function () {
      var top = viewport.scrollTop;
      var previous = state.lastScrollTop;
      state.lastScrollTop = top;
      if (state.mode !== 'scroll' || Date.now() < state.scrollSettle) {
        return;
      }
      var max = viewport.scrollHeight - viewport.clientHeight;
      var movedDown = top > previous + 0.5;
      var movedUp = top < previous - 0.5;
      // Only hand over when the reader reaches the very edge while moving
      // outward. Passing near an edge (for example the first scroll event
      // after a window opens at its top) must not bounce to another window.
      if (max > 0 && top >= max - 1 && movedDown && hasNextWindow()) {
        requestWindow('next');
        return;
      }
      if (top <= 0.5 && movedUp && hasPreviousWindow()) {
        requestWindow('prev');
        return;
      }
      clearTimeout(state.scrollTimer);
      state.scrollTimer = setTimeout(function () {
        reportPosition(false);
      }, 450);
    }, { passive: true });
    viewport.addEventListener('wheel', function (event) {
      if (state.mode !== 'paged') {
        return;
      }
      var now = Date.now();
      if (now - state.wheelTime < 320) {
        return;
      }
      var delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY;
      if (Math.abs(delta) < 8) {
        return;
      }
      state.wheelTime = now;
      event.preventDefault();
      if (delta > 0) {
        nextPage();
      } else {
        previousPage();
      }
    }, { passive: false });
  }

  function setMode(mode, columns) {
    var offset = currentOffset();
    state.mode = mode;
    if (columns) {
      config.columns = columns;
    }
    if (mode === 'scroll') {
      frame.style.overflow = 'visible';
      viewport.style.overflow = 'auto';
      viewport.style.overflowX = 'hidden';
      viewport.style.height = '100%';
      layoutScroll();
      scrollToOffset(offset);
      reportPosition(true);
    } else {
      frame.style.overflow = 'hidden';
      viewport.style.overflow = 'hidden';
      viewport.style.overflowY = 'hidden';
      viewport.scrollTop = 0;
      layout(false);
      goToPage(pageForOffset(offset));
    }
    post({ type: 'diag', message: 'mode ' + mode + ' offset=' + offset + '/' + state.totalChars +
      ' now=' + currentOffset() + ' global=' + globalProgress().toFixed(5) });
    post({ type: 'mode', mode: mode });
  }

  function setTypography(fontSize, lineHeight, margin, theme, fontFamily) {
    var progress = textProgressAtPage();
    if (progress <= 0 && state.page > 0) {
      progress = state.page / Math.max(1, state.pages);
    }
    config.fontSize = fontSize;
    config.lineHeight = lineHeight;
    config.margin = margin;
    config.theme = theme;
    config.fontFamily = fontFamily;
    applyTypography();
    if (state.mode === 'paged') {
      layout(false);
      goToPage(pageForOffset(Math.floor(progress * state.totalChars)));
    } else {
      layoutScroll();
      scrollToOffset(Math.floor(progress * state.totalChars));
    }
    reportPosition(true);
  }

  function setColumns(value) {
    var progress = textProgressAtPage();
    config.columns = value;
    if (state.mode === 'paged') {
      layout(false);
      goToPage(pageForOffset(Math.floor(progress * state.totalChars)));
    }
    reportPosition(true);
  }

  function goToProgress(progress) {
    if (state.totalChars <= 0) {
      return;
    }
    var global = clamp(progress, 0, 1);
    if (global < windowBase() - 0.000001 || global > windowBase() + windowSpan() + 0.000001) {
      requestWindowAt(global);
      return;
    }
    var offset = Math.floor(localProgressOf(global) * state.totalChars);
    if (state.mode === 'paged') {
      goToPage(pageForOffset(offset));
    } else {
      state.scrollSettle = Date.now() + 700;
      scrollToOffset(offset);
      reportPosition(true);
      post({ type: 'diag', message: 'seek ' + global.toFixed(5) + ' offset=' + offset +
        ' top=' + Math.round(viewport.scrollTop) });
    }
  }

  /**
   * Re-measures after the reading pane changed width (sidebar toggled,
   * window resized) and returns to an explicit text position. The position is
   * supplied by ArkTS so a temporary half-page state cannot become the anchor.
   */
  function reflow(progress) {
    var global = typeof progress === 'number' ? clamp(progress, 0, 1) : globalProgress();
    if (global < windowBase() - 0.000001 || global > windowBase() + windowSpan() + 0.000001) {
      requestWindowAt(global);
      return;
    }
    var target = localProgressOf(global);
    if (state.mode === 'scroll') {
      layoutScroll(false);
      scrollToOffset(Math.floor(target * state.totalChars));
      reportPosition(true);
    } else {
      layout(false);
      goToPage(pageForOffset(Math.floor(target * state.totalChars)));
    }
  }

  function loadLiveConfig() {
    try {
      if (window.easyread && window.easyread.getConfig) {
        var raw = window.easyread.getConfig();
        if (raw && raw.length > 2) {
          var live = JSON.parse(raw);
          if (live && typeof live === 'object') {
            var keys = ['mode', 'columns', 'fontSize', 'lineHeight', 'margin',
              'theme', 'fontFamily', 'textProgress', 'progress', 'locatorText',
              'windowBase', 'windowSpan'];
            for (var i = 0; i < keys.length; i++) {
              if (live[keys[i]] !== undefined) {
                config[keys[i]] = live[keys[i]];
              }
            }
          }
        }
      }
    } catch (error) {
    }
    state.mode = config.mode === 'scroll' ? 'scroll' : 'paged';
    state.columns = config.columns || 1;
  }

  function setup() {
    frame = document.getElementById('er-frame');
    viewport = document.getElementById('er-viewport');
    paged = document.getElementById('er-paged');
    if (!frame || !viewport || !paged) {
      return;
    }
    try {
      loadLiveConfig();
      applyTypography();
      bindTouch();
      document.addEventListener('keydown', onKey);
      window.addEventListener('resize', debounce(function () {
        if (viewport.clientWidth === state.viewWidth &&
          viewport.clientHeight === state.viewHeight) {
          return;
        }
        layout(true);
      }, 180));
      if (state.mode === 'scroll') {
        viewport.style.overflowY = 'auto';
        layoutScroll();
      } else {
        layout(false);
      }
      revealPage();
      post({ type: 'diag', message: 'setup viewport=' + viewport.clientWidth + 'x' + viewport.clientHeight +
        ' mode=' + state.mode + ' sections=' + document.querySelectorAll('section').length +
        ' text=' + document.body.textContent.length + ' pages=' + state.pages +
        ' at=' + Math.round(performance.now()) + 'ms' });
      post({ type: 'ready' });
      reportPosition(true);
    } catch (error) {
      paged.style.visibility = 'visible';
      post({ type: 'error', message: String(error && error.message ? error.message : error) });
    }
  }

  window.easyreadPager = {
    nextPage: nextPage,
    previousPage: previousPage,
    goToPage: goToPage,
    goToAnchor: goToAnchor,
    setMode: setMode,
    setTypography: setTypography,
    setColumns: setColumns,
    goToProgress: goToProgress,
    reflow: reflow,
    find: find,
    findNext: findNext,
    findPrevious: findPrevious,
    clearMarks: clearMarks,
    selectionText: selectionText,
    clearSelection: clearSelection,
    pageInfo: pageInfo,
    capture: function () {
      return { progress: globalProgress(), page: state.page + 1, pages: state.pages,
        windowBase: windowBase(), windowSpan: windowSpan() };
    }
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', setup);
  } else {
    setup();
  }
})();
`;
