/*
 * Carrossel de depoimentos da tela de login (PKG_ECLOUD_DEPOIMENTO.LOGIN_HTML).
 * Troca a cada 7 s, pausa com o mouse ou o foco em cima e não gira sozinho
 * para quem pediu menos movimento. Os pontos embaixo levam direto a um
 * depoimento.
 */
(function () {
    "use strict";

    var INTERVAL = 7000;

    function init(root) {
        var slides = Array.prototype.slice.call(root.querySelectorAll(".ec-quote"));
        var dots = Array.prototype.slice.call(root.querySelectorAll(".ec-quotes-dot"));
        var current = 0;
        var timer = null;
        var paused = false;
        var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

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

        root.addEventListener("mouseenter", function () { paused = true; });
        root.addEventListener("mouseleave", function () { paused = false; });
        root.addEventListener("focusin", function () { paused = true; });
        root.addEventListener("focusout", function () { paused = false; });

        if (slides.length) {
            show(0);
            schedule();
        }
    }

    function start() {
        Array.prototype.forEach.call(document.querySelectorAll("[data-ec-quotes]"), init);
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", start);
    } else {
        start();
    }
})();
