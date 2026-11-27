/*
 * Carrossel de anúncios da tela de login (PKG_ECLOUD_ANUNCIO.LOGIN_HTML).
 * Troca de anúncio a cada 8 s, pausa com o mouse ou o foco em cima e não gira
 * sozinho para quem pediu menos movimento. Cada anúncio que aparece na tela
 * conta uma exibição (uma vez por carregamento) e o clique no botão do
 * anunciante é contado à parte; o link abre direto em outra aba.
 *
 * As contagens vão para o processo de aplicação ANUNCIO_EVENTO (Ajax Callback)
 * pelo apex.server.process: x01 = id do anúncio, x02 = EXIBICAO ou CLIQUE.
 * Erro na contagem nunca aparece para o usuário.
 *
 * Também cuida da página "Ofertas e parceiros" (PKG_ECLOUD_ANUNCIO.OFERTAS_HTML):
 * lá os anúncios ficam em cartões e cada um conta a exibição quando metade dele
 * aparece na tela.
 */
(function () {
    "use strict";

    var INTERVAL = 8000;
    var PROCESSO = "ANUNCIO_EVENTO";

    function send(id, evento) {
        if (!id || !window.apex || !apex.server) {
            return;
        }
        try {
            apex.server.process(PROCESSO, { x01: id, x02: evento }, {
                dataType: "text",
                loadingIndicator: null
            }).catch(function () { /* contagem não é crítica */ });
        } catch (e) { /* idem */ }
    }

    // Clique (inclusive com o botão do meio) no link do anunciante.
    function countClick(event) {
        var cta = event.target.closest && event.target.closest(".ec-ad-cta");
        var ad = cta && cta.closest(".ec-ad");
        if (ad && (event.type === "click" || event.button === 1)) {
            send(ad.getAttribute("data-ad-id"), "CLIQUE");
        }
    }

    function initGrid(root) {
        var cards = Array.prototype.slice.call(root.querySelectorAll(".ec-ad"));
        root.addEventListener("click", countClick);
        root.addEventListener("auxclick", countClick);
        if (!("IntersectionObserver" in window)) {
            cards.forEach(function (card) { send(card.getAttribute("data-ad-id"), "EXIBICAO"); });
            return;
        }
        var observer = new IntersectionObserver(function (entries) {
            entries.forEach(function (entry) {
                if (entry.isIntersecting && document.visibilityState !== "hidden") {
                    observer.unobserve(entry.target);
                    send(entry.target.getAttribute("data-ad-id"), "EXIBICAO");
                }
            });
        }, { threshold: 0.5 });
        cards.forEach(function (card) { observer.observe(card); });
    }

    function init(root) {
        var slides = Array.prototype.slice.call(root.querySelectorAll(".ec-ad"));
        var dots = Array.prototype.slice.call(root.querySelectorAll(".ec-ads-dot"));
        var seen = {};
        var current = 0;
        var timer = null;
        var paused = false;
        var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

        function countView(slide) {
            var id = slide.getAttribute("data-ad-id");
            if (!id || seen[id] || document.visibilityState === "hidden") {
                return;
            }
            // Vitrine escondida (sem espaço na tela): não conta.
            if (!root.offsetParent && getComputedStyle(root).position !== "fixed") {
                return;
            }
            seen[id] = true;
            send(id, "EXIBICAO");
        }

        function show(index) {
            current = (index + slides.length) % slides.length;
            slides.forEach(function (slide, i) {
                var on = i === current;
                slide.classList.toggle("is-active", on);
                slide.hidden = !on;
            });
            dots.forEach(function (dot, i) {
                var on = i === current;
                dot.classList.toggle("is-active", on);
                if (on) {
                    dot.setAttribute("aria-current", "true");
                } else {
                    dot.removeAttribute("aria-current");
                }
            });
            countView(slides[current]);
        }

        function schedule() {
            clearInterval(timer);
            if (slides.length > 1 && !reduceMotion) {
                timer = setInterval(function () {
                    if (!paused && document.visibilityState !== "hidden") {
                        show(current + 1);
                    }
                }, INTERVAL);
            }
        }

        dots.forEach(function (dot, i) {
            dot.addEventListener("click", function () {
                show(i);
                schedule();
            });
        });

        root.addEventListener("click", countClick);
        root.addEventListener("auxclick", countClick);

        root.addEventListener("mouseenter", function () { paused = true; });
        root.addEventListener("mouseleave", function () { paused = false; });
        root.addEventListener("focusin", function () { paused = true; });
        root.addEventListener("focusout", function () { paused = false; });
        document.addEventListener("visibilitychange", function () {
            if (document.visibilityState === "visible") {
                countView(slides[current]);
            }
        });

        if (slides.length) {
            show(0);
            schedule();
        }
    }

    function start() {
        Array.prototype.forEach.call(document.querySelectorAll("[data-ec-ads]"), init);
        Array.prototype.forEach.call(document.querySelectorAll("[data-ec-ads-grid]"), initGrid);
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", start);
    } else {
        start();
    }
})();
