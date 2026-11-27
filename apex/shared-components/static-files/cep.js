/*
 * Busca de endereço pelo CEP (adaptada do Mecânico VIP).
 * Qualquer item cujo nome termina em _CEP (ex.: P21_CEP) preenche os itens
 * irmãos de mesmo prefixo que existirem na página:
 *   _ENDERECO       logradouro
 *   _BAIRRO         bairro
 *   _UF             sigla da UF
 *   _MUNICIPIO_IBGE código IBGE do município (depois que a lista em cascata
 *                   da UF é recarregada)
 * e leva o cursor para _NUMERO. Consulta o ViaCEP e, se ele falhar, a
 * BrasilAPI, direto do navegador (serviços públicos, sem chave). A gravação
 * continua validada no servidor (CEP, UF e município).
 */
(function () {
    "use strict";

    var SOURCES = [
        function (cep) {
            return fetch("https://viacep.com.br/ws/" + cep + "/json/").then(function (r) {
                if (!r.ok) { throw new Error("viacep " + r.status); }
                return r.json();
            }).then(function (d) {
                if (d.erro) { return null; }
                return { street: d.logradouro, district: d.bairro, city: d.localidade, state: d.uf, ibge: d.ibge };
            });
        },
        function (cep) {
            return fetch("https://brasilapi.com.br/api/cep/v1/" + cep).then(function (r) {
                if (r.status === 404) { return null; }
                if (!r.ok) { throw new Error("brasilapi " + r.status); }
                return r.json().then(function (d) {
                    // A BrasilAPI não traz o código IBGE: o município fica para o usuário.
                    return { street: d.street, district: d.neighborhood, city: d.city, state: d.state, ibge: null };
                });
            });
        }
    ];

    function lookup(cep) {
        var i = 0;
        function next() {
            if (i >= SOURCES.length) {
                return Promise.reject(new Error("indisponível"));
            }
            return SOURCES[i++](cep).catch(next);
        }
        return next();
    }

    function exists(name) {
        return !!document.getElementById(name);
    }

    function setItem(name, value) {
        if (exists(name) && value) {
            apex.item(name).setValue(value);
        }
    }

    // Município: a lista depende da UF (cascata). Se a UF muda, espera a lista
    // recarregar antes de gravar o código, senão a cascata apaga o valor.
    function setStateAndCity(prefix, addr) {
        var uf = prefix + "UF";
        var mun = prefix + "MUNICIPIO_IBGE";
        function setCity() {
            if (exists(mun) && addr.ibge) {
                apex.item(mun).setValue(addr.ibge, addr.city + " (" + addr.ibge + ")");
            }
        }
        if (!exists(uf) || !addr.state) {
            setCity();
            return;
        }
        if (apex.item(uf).getValue() === addr.state) {
            setCity();
            return;
        }
        if (exists(mun)) {
            apex.jQuery("#" + mun).one("apexafterrefresh", setCity);
        }
        apex.item(uf).setValue(addr.state);
        if (!exists(mun)) {
            setCity();
        }
    }

    function showError(item, text) {
        apex.message.clearErrors();
        apex.message.showErrors([{ type: "error", location: "inline", pageItem: item, message: text, unsafe: false }]);
    }

    function bind(input) {
        var item = input.id;
        var prefix = item.slice(0, -"CEP".length);
        var last = null;

        function run() {
            var cep = (input.value || "").replace(/\D/g, "");
            if (cep.length !== 8 || cep === last) {
                return;
            }
            last = cep;
            apex.item(item).setValue(cep.slice(0, 5) + "-" + cep.slice(5), null, true);
            input.classList.add("ec-cep-loading");
            lookup(cep).then(function (addr) {
                if (!addr) {
                    showError(item, "CEP não encontrado. Confira os números ou preencha o endereço.");
                    return;
                }
                apex.message.clearErrors();
                setItem(prefix + "ENDERECO", addr.street);
                setItem(prefix + "BAIRRO", addr.district);
                setStateAndCity(prefix, addr);
                var number = document.getElementById(prefix + "NUMERO");
                if (number) { number.focus(); }
            }, function () {
                last = null;
                showError(item, "Não foi possível consultar o CEP agora. Preencha o endereço.");
            }).then(function () {
                input.classList.remove("ec-cep-loading");
            });
        }

        input.setAttribute("inputmode", "numeric");
        input.setAttribute("autocomplete", "postal-code");
        input.addEventListener("input", run);
        input.addEventListener("change", run);
    }

    function boot() {
        Array.prototype.forEach.call(document.querySelectorAll("input[id$='_CEP']"), bind);
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", boot);
    } else {
        boot();
    }
})();
