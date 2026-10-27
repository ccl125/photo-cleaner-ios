(() => {
  const toggle = document.querySelector('.nav-toggle');
  const nav = document.querySelector('.site-nav');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  const closeNav = () => {
    toggle.setAttribute('aria-expanded', 'false');
    toggle.setAttribute('aria-label', '打开导航');
    nav.classList.remove('open');
  };

  toggle.addEventListener('click', () => {
    const isOpen = toggle.getAttribute('aria-expanded') === 'true';
    toggle.setAttribute('aria-expanded', String(!isOpen));
    toggle.setAttribute('aria-label', isOpen ? '打开导航' : '关闭导航');
    nav.classList.toggle('open', !isOpen);
  });

  nav.addEventListener('click', (event) => {
    if (event.target.closest('a')) closeNav();
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      closeNav();
      toggle.focus();
    }
  });

  document.addEventListener('click', (event) => {
    if (!event.target.closest('.header-inner')) closeNav();
  });

  const desktop = window.matchMedia('(min-width: 761px)');
  desktop.addEventListener('change', (event) => {
    if (event.matches) closeNav();
  });

  let ticking = false;
  const updateParallax = () => {
    const mosaic = document.querySelector('[data-parallax-container]');
    if (mosaic && !reducedMotion.matches) {
      const rect = mosaic.getBoundingClientRect();
      const centerOffset = rect.top + rect.height / 2 - window.innerHeight / 2;
      const shift = Math.max(-18, Math.min(18, centerOffset * -0.025));
      mosaic.style.setProperty('--mosaic-shift', `${shift}px`);
    }
    ticking = false;
  };

  window.addEventListener('scroll', () => {
    if (!ticking && !reducedMotion.matches) {
      window.requestAnimationFrame(updateParallax);
      ticking = true;
    }
  }, { passive: true });

  reducedMotion.addEventListener('change', () => {
    if (reducedMotion.matches) {
      document.querySelector('[data-parallax-container]').style.removeProperty('--mosaic-shift');
    }
  });

  updateParallax();
})();
