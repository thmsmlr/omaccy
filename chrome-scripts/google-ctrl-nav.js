// Google Ctrl-N/P Navigation
(() => {
    let i = -1;
    const results = () => [...document.querySelectorAll('a h3')].map(h => h.parentElement);
    function jump(step) {
        const list = results();
        if (!list.length) return;
        // Clear previous highlight
        list.forEach(el => el.style.outline = '');

        i = Math.max(0, Math.min(i + step, list.length - 1));
        const el = list[i];
        el.focus();
        el.scrollIntoView({ block: 'center' });
        // Add visible highlight to the active element
        el.style.outline = '3px solid #4285f4';
    }
    window.addEventListener('keydown', e => {
        if (e.key.toLowerCase() === 'j') { e.preventDefault(); jump(+1); }
        if (e.key.toLowerCase() === 'k') { e.preventDefault(); jump(-1); }
    }, true);
})();