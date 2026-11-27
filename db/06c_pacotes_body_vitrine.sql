--------------------------------------------------------------------------------
-- 06c_pacotes_body_vitrine.sql
-- Bodies dos pacotes da vitrine da tela de login (specs em
-- 03c_pacotes_spec_vitrine.sql). Chamado por 06_pacotes_body.sql.
--
-- O HTML gerado usa as classes ec-* do app.css (fase 3) e é sempre escapado
-- com APEX_ESCAPE. HTTP só pelo PKG_RTC_HTTP (serviço MIDIA), com log.
-- Idempotente (CREATE OR REPLACE).
--------------------------------------------------------------------------------
set define off

create or replace package body pkg_ecloud_anuncio
as
    ----------------------------------------------------------------------------
    -- Apoio
    ----------------------------------------------------------------------------
    function esc(p_texto in varchar2) return varchar2 is
    begin
        return apex_escape.html(p_texto);
    end esc;

    function attr(p_texto in varchar2) return varchar2 is
    begin
        return apex_escape.html_attribute(p_texto);
    end attr;

    procedure exigir_plataforma is
    begin
        if not (pkg_ecloud_ctx.is_admin_plataforma or pkg_ecloud_ctx.is_sistema) then
            raise_application_error(c_err_permissao, 'Somente o administrador da plataforma pode alterar anúncios.');
        end if;
    end exigir_plataforma;

    function cor_contraste(p_cor in varchar2) return varchar2 deterministic is
        -- Canal sRGB linearizado (WCAG 2.x).
        function canal(p_pos in pls_integer) return number is
            l_c number := to_number(substr(p_cor, p_pos, 2), 'XX') / 255;
        begin
            return case when l_c <= 0.03928 then l_c / 12.92 else power((l_c + 0.055) / 1.055, 2.4) end;
        end canal;
    begin
        return case when 0.2126 * canal(2) + 0.7152 * canal(4) + 0.0722 * canal(6) > 0.22
                    then '#1C2230' else '#FFFFFF' end;
    exception
        when others then
            return '#1C2230';
    end cor_contraste;

    function etiquetas_html(p_etiquetas in varchar2) return varchar2 is
        l_html varchar2(4000);
    begin
        for t in (select trim(column_value) etiqueta
                    from table(apex_string.split(p_etiquetas, ';'))
                   where trim(column_value) is not null)
        loop
            l_html := l_html || '<li>' || esc(t.etiqueta) || '</li>';
        end loop;
        return case when l_html is not null then '<ul class="ec-ad-tags">' || l_html || '</ul>' end;
    end etiquetas_html;

    -- Corpo de um anúncio (igual no login e nos cartões de Ofertas).
    function conteudo_html(p_anuncio in anuncio%rowtype, p_img_url in varchar2) return varchar2 is
    begin
        return case when p_img_url is not null then
                   '<div class="ec-ad-media"><img src="' || attr(p_img_url)
                   || '" alt="' || attr(p_anuncio.patrocinador) || '" loading="lazy"></div>' end
            || '<div class="ec-ad-content">'
            || case when p_anuncio.chamada is not null then
                   '<span class="ec-ad-pill"><span class="ec-ad-dot" aria-hidden="true"></span>'
                   || esc(p_anuncio.chamada) || '</span>' end
            || '<p class="ec-ad-sponsor">' || esc(p_anuncio.patrocinador) || '</p>'
            || '<h2 class="ec-ad-title">' || esc(p_anuncio.titulo)
            || case when p_anuncio.destaque is not null then
                   ' <span class="ec-ad-highlight">' || esc(p_anuncio.destaque) || '</span>' end
            || '</h2>'
            || case when p_anuncio.texto is not null then '<p class="ec-ad-body">' || esc(p_anuncio.texto) || '</p>' end
            || etiquetas_html(p_anuncio.etiquetas)
            || case when p_anuncio.botao_url is not null then
                   '<a class="ec-ad-cta" href="' || attr(p_anuncio.botao_url)
                   || '" target="_blank" rel="noopener sponsored">'
                   || esc(coalesce(p_anuncio.botao_rotulo, 'Saiba mais'))
                   || ' <span class="fa fa-arrow-right" aria-hidden="true"></span></a>' end
            || '</div>';
    end conteudo_html;

    function estilo_cor(p_cor in varchar2) return varchar2 is
    begin
        return ' style="--ec-ad-accent:' || p_cor || ';--ec-ad-on-accent:' || cor_contraste(p_cor) || '"';
    end estilo_cor;

    ----------------------------------------------------------------------------
    -- HTML
    ----------------------------------------------------------------------------
    function login_html return clob is
        l_html    clob;
        l_pontos  varchar2(4000);
        l_n       pls_integer := 0;
        l_img     varchar2(2000);
    begin
        for a in (select *
                    from anuncio
                   where ativo = 'S'
                     and exibir_login = 'S'
                     and (inicio_em is null or inicio_em <= trunc(sysdate))
                     and (fim_em is null or fim_em >= trunc(sysdate))
                   order by ordem, anuncio_id)
        loop
            l_n   := l_n + 1;
            l_img := imagem_url(a.anuncio_id);
            l_html := l_html
                || '<article class="ec-ad' || case when l_n = 1 then ' is-active' end || '"'
                || ' id="ec-ad-' || a.anuncio_id || '" data-ad-id="' || a.anuncio_id || '"'
                || estilo_cor(a.cor_destaque)
                || ' aria-roledescription="anúncio"' || case when l_n > 1 then ' hidden' end || '>'
                || conteudo_html(a, l_img)
                -- Sem imagem: órbita decorativa na cor do anúncio, no canto.
                || case when l_img is null then
                       '<div class="ec-ad-orbit" aria-hidden="true"><span></span><span></span><span></span></div>' end
                || '</article>';
            l_pontos := l_pontos
                || '<button type="button" class="ec-ads-dot' || case when l_n = 1 then ' is-active' end || '"'
                || ' aria-controls="ec-ad-' || a.anuncio_id || '" aria-label="Anúncio ' || l_n || '"'
                || case when l_n = 1 then ' aria-current="true"' end || '></button>';
        end loop;
        if l_n = 0 then
            return null;
        end if;
        return '<aside class="ec-ads" aria-label="Anúncios" data-ec-ads>'
            || '<div class="ec-ads-track">' || l_html || '</div>'
            || '<div class="ec-ads-foot"><span class="ec-ads-label">Publicidade</span>'
            || case when l_n > 1 then '<div class="ec-ads-dots">' || l_pontos || '</div>' end
            || '</div></aside>';
    end login_html;

    function ofertas_html return clob is
        l_html clob;
        l_n    pls_integer := 0;
    begin
        for a in (select *
                    from anuncio
                   where ativo = 'S'
                     and exibir_ofertas = 'S'
                     and (inicio_em is null or inicio_em <= trunc(sysdate))
                     and (fim_em is null or fim_em >= trunc(sysdate))
                   order by ordem, anuncio_id)
        loop
            l_n := l_n + 1;
            l_html := l_html
                || '<article class="ec-ad ec-ad-card" data-ad-id="' || a.anuncio_id || '"'
                || estilo_cor(a.cor_destaque) || ' aria-roledescription="anúncio">'
                || conteudo_html(a, imagem_url(a.anuncio_id))
                || '</article>';
        end loop;
        if l_n = 0 then
            return '<p class="ec-empty">Nenhuma oferta no ar agora. Volte em breve.</p>';
        end if;
        return '<section class="ec-ads-grid" aria-label="Ofertas e parceiros" data-ec-ads-grid>'
            || l_html || '</section>';
    end ofertas_html;

    ----------------------------------------------------------------------------
    -- Contadores
    ----------------------------------------------------------------------------
    procedure somar(p_anuncio_id in number, p_exibicoes in pls_integer, p_cliques in pls_integer) is
        pragma autonomous_transaction;
    begin
        merge into anuncio_estatistica d
        using (select anuncio_id, trunc(sysdate) dia from anuncio where anuncio_id = p_anuncio_id) s
           on (d.anuncio_id = s.anuncio_id and d.dia = s.dia)
         when matched then update set d.exibicoes = d.exibicoes + p_exibicoes, d.cliques = d.cliques + p_cliques
         when not matched then insert (anuncio_id, dia, exibicoes, cliques)
              values (s.anuncio_id, s.dia, p_exibicoes, p_cliques);
        commit;
    exception
        when dup_val_on_index then
            -- Dois acessos no primeiro instante do dia: soma na linha que ganhou.
            update anuncio_estatistica
               set exibicoes = exibicoes + p_exibicoes, cliques = cliques + p_cliques
             where anuncio_id = p_anuncio_id and dia = trunc(sysdate);
            commit;
    end somar;

    procedure registrar_exibicao(p_anuncio_id in number) is
    begin
        somar(p_anuncio_id, 1, 0);
    end registrar_exibicao;

    function registrar_clique(p_anuncio_id in number) return varchar2 is
        l_url anuncio.botao_url%type;
    begin
        select botao_url into l_url from anuncio where anuncio_id = p_anuncio_id;
        if l_url is not null then
            somar(p_anuncio_id, 0, 1);
        end if;
        return l_url;
    exception
        when no_data_found then
            return null;
    end registrar_clique;

    procedure registrar_evento(p_anuncio_id in number, p_evento in varchar2) is
        l_url anuncio.botao_url%type;
    begin
        case upper(p_evento)
            when 'EXIBICAO' then registrar_exibicao(p_anuncio_id);
            when 'CLIQUE'   then l_url := registrar_clique(p_anuncio_id);
            else null;
        end case;
    exception
        when value_error or invalid_number then
            null;   -- id inválido vindo do navegador
    end registrar_evento;

    ----------------------------------------------------------------------------
    -- Imagem no R2
    ----------------------------------------------------------------------------
    function caminho_objeto(p_chave in varchar2) return varchar2 is
    begin
        return pkg_rtc_http.c_path_midia_objetos || '/' || p_chave;
    end caminho_objeto;

    -- Falha ao apagar fica registrada no log de chamadas e não trava a tela.
    procedure apagar_objeto(p_anuncio_id in number, p_chave in varchar2) is
        l_resp pkg_rtc_http.t_resposta;
    begin
        if p_chave is null then
            return;
        end if;
        l_resp := pkg_rtc_http.delete_recurso(
            p_servico         => pkg_rtc_http.c_servico_midia,
            p_caminho         => caminho_objeto(p_chave),
            p_operacao        => 'APAGAR_IMAGEM_ANUNCIO',
            p_referencia_tipo => 'ANUNCIO',
            p_referencia_id   => p_anuncio_id);
    exception
        when others then
            null;
    end apagar_objeto;

    procedure salvar_imagem(p_anuncio_id in number, p_temp_file_name in varchar2) is
        l_antiga  anuncio.imagem_chave%type;
        l_chave   anuncio.imagem_chave%type;
        l_ext     varchar2(10);
        l_resp    pkg_rtc_http.t_resposta;
        l_achou   boolean := false;
    begin
        if p_temp_file_name is null then
            return;
        end if;
        exigir_plataforma;
        select imagem_chave into l_antiga from anuncio where anuncio_id = p_anuncio_id;

        for f in (select blob_content, lower(mime_type) mime_type, filename
                    from apex_application_temp_files
                   where name = p_temp_file_name)
        loop
            l_achou := true;
            if instr(',' || c_imagem_tipos || ',', ',' || f.mime_type || ',') = 0 then
                raise_application_error(c_err_entrada, 'Envie a imagem em PNG, JPG, WebP ou GIF.');
            end if;
            if dbms_lob.getlength(f.blob_content) > c_imagem_max_bytes then
                raise_application_error(c_err_entrada,
                    'A imagem passa de ' || round(c_imagem_max_bytes / 1048576) || ' MB. Reduza o tamanho e envie de novo.');
            end if;
            l_ext := case f.mime_type
                         when 'image/png'  then 'png'
                         when 'image/jpeg' then 'jpg'
                         when 'image/webp' then 'webp'
                         when 'image/gif'  then 'gif'
                     end;
            l_chave := c_pasta_imagens || '/' || p_anuncio_id || '/' || lower(rawtohex(sys_guid())) || '.' || l_ext;

            l_resp := pkg_rtc_http.put_blob(
                p_servico         => pkg_rtc_http.c_servico_midia,
                p_caminho         => caminho_objeto(l_chave),
                p_corpo           => f.blob_content,
                p_content_type    => f.mime_type,
                p_operacao        => 'ENVIAR_IMAGEM_ANUNCIO',
                p_referencia_tipo => 'ANUNCIO',
                p_referencia_id   => p_anuncio_id);
            if l_resp.erro is not null or nvl(l_resp.http_status, 0) not in (200, 201) then
                raise_application_error(c_err_armazenamento,
                    'O armazenamento de imagens recusou o envio ('
                    || case when l_resp.http_status is not null then 'HTTP ' || l_resp.http_status
                            else 'sem conexão' end
                    || '). Tente de novo; detalhes no log de chamadas.');
            end if;

            update anuncio
               set imagem_chave  = l_chave,
                   imagem_mime   = f.mime_type,
                   imagem_nome   = substr(f.filename, 1, 255),
                   imagem_versao = imagem_versao + 1
             where anuncio_id = p_anuncio_id;
        end loop;

        if l_achou and l_antiga is not null and l_antiga <> l_chave then
            apagar_objeto(p_anuncio_id, l_antiga);
        end if;
    end salvar_imagem;

    procedure remover_imagem(p_anuncio_id in number) is
        l_antiga anuncio.imagem_chave%type;
    begin
        exigir_plataforma;
        select imagem_chave into l_antiga from anuncio where anuncio_id = p_anuncio_id;
        update anuncio
           set imagem_chave = null, imagem_mime = null, imagem_nome = null,
               imagem_versao = imagem_versao + 1
         where anuncio_id = p_anuncio_id;
        apagar_objeto(p_anuncio_id, l_antiga);
    exception
        when no_data_found then
            null;
    end remover_imagem;

    function imagem_url(p_anuncio_id in number) return varchar2 is
        l_base   varchar2(1000) := pkg_rtc_config.valor(pkg_rtc_config.c_midia_base_url, false);
        l_chave  anuncio.imagem_chave%type;
        l_versao anuncio.imagem_versao%type;
    begin
        if l_base is null then
            return null;
        end if;
        select imagem_chave, imagem_versao into l_chave, l_versao
          from anuncio
         where anuncio_id = p_anuncio_id;
        if l_chave is null then
            return null;
        end if;
        return rtrim(l_base, '/') || caminho_objeto(l_chave) || '?v=' || l_versao;
    exception
        when no_data_found then
            return null;
    end imagem_url;

    ----------------------------------------------------------------------------
    -- Administração
    ----------------------------------------------------------------------------
    function estatistica_rotulo(p_anuncio_id in number, p_dias in pls_integer default 30) return varchar2 is
        l_exib  number;
        l_cliq  number;
        c_nls   constant varchar2(40) := q'[nls_numeric_characters=',.']';
    begin
        select nvl(sum(exibicoes), 0), nvl(sum(cliques), 0)
          into l_exib, l_cliq
          from anuncio_estatistica
         where anuncio_id = p_anuncio_id
           and dia > trunc(sysdate) - p_dias;
        return to_char(l_exib, 'FM999G999G990', c_nls) || case l_exib when 1 then ' exibição' else ' exibições' end
            || ' · ' || to_char(l_cliq, 'FM999G999G990', c_nls) || case l_cliq when 1 then ' clique' else ' cliques' end
            || case when l_exib > 0 then
                   ' · ' || to_char(round(100 * l_cliq / l_exib, 1), 'FM990D0', c_nls) || '%' end;
    end estatistica_rotulo;

    function situacao(p_anuncio_id in number) return varchar2 is
        l_a anuncio%rowtype;
    begin
        select * into l_a from anuncio where anuncio_id = p_anuncio_id;
        return case
                   when l_a.ativo = 'N'                         then 'INATIVO'
                   when l_a.inicio_em > trunc(sysdate)           then 'AGENDADO'
                   when l_a.fim_em < trunc(sysdate)              then 'ENCERRADO'
                   else 'NO_AR'
               end;
    exception
        when no_data_found then
            return null;
    end situacao;
end pkg_ecloud_anuncio;
/

create or replace package body pkg_ecloud_depoimento
as
    function esc(p_texto in varchar2) return varchar2 is
    begin
        return apex_escape.html(p_texto);
    end esc;

    procedure exigir_plataforma is
    begin
        if not (pkg_ecloud_ctx.is_admin_plataforma or pkg_ecloud_ctx.is_sistema) then
            raise_application_error(c_err_permissao, 'Somente a equipe da plataforma revisa depoimentos.');
        end if;
    end exigir_plataforma;

    function estrelas(p_nota in number) return varchar2 is
    begin
        return '<span class="ec-quote-stars" role="img" aria-label="' || p_nota || ' de 5 estrelas">'
            || rpad('★', p_nota, '★')
            || case when p_nota < 5 then
                   '<span class="ec-quote-stars-off">' || rpad('★', 5 - p_nota, '★') || '</span>' end
            || '</span>';
    end estrelas;

    function login_html return clob is
        l_html   clob;
        l_pontos varchar2(4000);
        l_n      pls_integer := 0;
    begin
        -- Sem escritório no contexto (tela de login), o VPD já deixa só os APROVADOS;
        -- o filtro explícito vale para quando há contexto.
        for d in (select depoimento_id, autor_nome, autor_cargo, escritorio_nome, cidade, texto, nota
                    from depoimento
                   where status = 'APROVADO'
                   order by revisado_em desc nulls last, depoimento_id desc
                   fetch first c_max_login rows only)
        loop
            l_n := l_n + 1;
            l_html := l_html
                || '<figure class="ec-quote' || case when l_n = 1 then ' is-active' end || '"'
                || ' id="ec-quote-' || d.depoimento_id || '" aria-roledescription="depoimento"'
                || case when l_n > 1 then ' hidden' end || '>'
                || estrelas(d.nota)
                || '<blockquote class="ec-quote-text"><p>“' || esc(d.texto) || '”</p></blockquote>'
                || '<figcaption class="ec-quote-author">'
                || '<span class="ec-quote-avatar" aria-hidden="true">' || esc(upper(substr(d.autor_nome, 1, 1))) || '</span>'
                || '<span><strong>' || esc(d.autor_nome) || '</strong>'
                || '<span class="ec-quote-meta">'
                || esc(d.autor_cargo || case when d.autor_cargo is not null then ', ' end || d.escritorio_nome)
                || case when d.cidade is not null then ' · ' || esc(d.cidade) end
                || '</span></span></figcaption>'
                || '</figure>';
            l_pontos := l_pontos
                || '<button type="button" class="ec-ads-dot ec-quotes-dot' || case when l_n = 1 then ' is-active' end || '"'
                || ' aria-controls="ec-quote-' || d.depoimento_id || '" aria-label="Depoimento ' || l_n || '"'
                || case when l_n = 1 then ' aria-current="true"' end || '></button>';
        end loop;
        if l_n = 0 then
            return null;
        end if;
        return '<section class="ec-quotes" aria-label="Depoimentos de escritórios" data-ec-quotes>'
            || '<p class="ec-quotes-label">Quem usa, recomenda</p>'
            || '<div class="ec-quotes-track" aria-live="polite">' || l_html || '</div>'
            || case when l_n > 1 then '<div class="ec-quotes-dots">' || l_pontos || '</div>' end
            || '</section>';
    end login_html;

    function meu_id return number is
        l_id depoimento.depoimento_id%type;
    begin
        select depoimento_id into l_id
          from depoimento
         where autor_username = sys_context('CTX_ECLOUD', 'USERNAME');
        return l_id;
    exception
        when no_data_found then
            return null;
    end meu_id;

    function sugestao_autor return varchar2 is
        l_nome usuario.nome%type;
    begin
        select nome into l_nome from usuario where usuario_id = pkg_ecloud_ctx.usuario_id;
        return substr(l_nome, 1, 120);
    exception
        when no_data_found then
            return null;
    end sugestao_autor;

    function sugestao_escritorio return varchar2 is
        l_nome escritorio.razao_social%type;
    begin
        select coalesce(nome_fantasia, razao_social) into l_nome
          from escritorio
         where escritorio_id = pkg_ecloud_ctx.escritorio_id;
        return substr(l_nome, 1, 120);
    exception
        when no_data_found then
            return null;
    end sugestao_escritorio;

    function sugestao_cidade return varchar2 is
        l_cidade varchar2(200);
    begin
        -- Nome do município pelo cache dos dados abertos; sem cache, só a UF.
        select case when m.nome is not null then m.nome || '/' end || e.uf
          into l_cidade
          from escritorio e
          left join rtc_da_municipio m on m.codigo = e.municipio_ibge
         where e.escritorio_id = pkg_ecloud_ctx.escritorio_id;
        return substr(l_cidade, 1, 120);
    exception
        when no_data_found then
            return null;
    end sugestao_cidade;

    procedure salvar_meu(
        p_autor_nome      in varchar2,
        p_autor_cargo     in varchar2,
        p_escritorio_nome in varchar2,
        p_cidade          in varchar2,
        p_texto           in varchar2,
        p_nota            in number)
    is
        l_id depoimento.depoimento_id%type;
    begin
        if pkg_ecloud_ctx.escritorio_id is null or pkg_ecloud_ctx.username is null then
            raise_application_error(c_err_permissao, 'Só usuários de escritório podem deixar depoimento.');
        end if;
        if length(trim(regexp_replace(p_texto, '\s+', ' '))) < 20 or p_texto is null then
            raise_application_error(c_err_entrada, 'Escreva pelo menos 20 caracteres no depoimento.');
        end if;
        if trim(p_autor_nome) is null or trim(p_escritorio_nome) is null then
            raise_application_error(c_err_entrada, 'Informe o seu nome e o nome do escritório.');
        end if;
        if nvl(p_nota, 5) not between 1 and 5 then
            raise_application_error(c_err_entrada, 'A nota vai de 1 a 5 estrelas.');
        end if;

        l_id := meu_id;
        if l_id is null then
            insert into depoimento (autor_nome, autor_cargo, escritorio_nome, cidade, texto, nota)
            values (p_autor_nome, p_autor_cargo, p_escritorio_nome, p_cidade, p_texto, nvl(p_nota, 5));
        else
            update depoimento
               set autor_nome      = p_autor_nome,
                   autor_cargo     = p_autor_cargo,
                   escritorio_nome = p_escritorio_nome,
                   cidade          = p_cidade,
                   texto           = p_texto,
                   nota            = nvl(p_nota, 5)
             where depoimento_id = l_id;
        end if;
    end salvar_meu;

    procedure excluir_meu is
    begin
        delete from depoimento where autor_username = sys_context('CTX_ECLOUD', 'USERNAME');
    end excluir_meu;

    function situacao_html(p_depoimento_id in number) return varchar2 is
        l_status depoimento.status%type;
        l_motivo depoimento.motivo_reprovacao%type;
    begin
        if p_depoimento_id is null then
            return '<div class="ec-notice ec-notice--info"><span class="fa fa-comment-o" aria-hidden="true"></span>'
                || '<p>Conte como o Ecloud ajuda o seu escritório. Depois de aprovado pela nossa equipe, '
                || 'o seu depoimento aparece na tela de entrada do sistema.</p></div>';
        end if;
        select status, motivo_reprovacao into l_status, l_motivo
          from depoimento
         where depoimento_id = p_depoimento_id;
        return case l_status
            when 'APROVADO' then
                '<div class="ec-notice ec-notice--success"><span class="fa fa-check-circle" aria-hidden="true"></span>'
                || '<p><strong>Aprovado.</strong> Seu depoimento está no ar na tela de entrada. '
                || 'Se mudar o texto, ele volta para aprovação.</p></div>'
            when 'REPROVADO' then
                '<div class="ec-notice ec-notice--danger"><span class="fa fa-times-circle" aria-hidden="true"></span>'
                || '<p><strong>Não aprovado.</strong> ' || esc(l_motivo)
                || ' Ajuste o texto e envie de novo.</p></div>'
            else
                '<div class="ec-notice ec-notice--warning"><span class="fa fa-clock-o" aria-hidden="true"></span>'
                || '<p><strong>Aguardando aprovação.</strong> Nossa equipe revisa os depoimentos antes de publicar.</p></div>'
        end;
    exception
        when no_data_found then
            return null;
    end situacao_html;

    procedure revisar(p_depoimento_id in number, p_status in varchar2, p_motivo in varchar2) is
    begin
        exigir_plataforma;
        update depoimento
           set status            = p_status,
               motivo_reprovacao = substr(trim(p_motivo), 1, 400),
               revisado_em       = systimestamp,
               revisado_por      = coalesce(sys_context('APEX$SESSION', 'APP_USER'), pkg_ecloud_ctx.username, user)
         where depoimento_id = p_depoimento_id;
        if sql%rowcount = 0 then
            raise_application_error(c_err_nao_encontrado, 'Depoimento não encontrado.');
        end if;
    end revisar;

    procedure aprovar(p_depoimento_id in number) is
    begin
        revisar(p_depoimento_id, 'APROVADO', null);
    end aprovar;

    procedure reprovar(p_depoimento_id in number, p_motivo in varchar2) is
    begin
        if trim(p_motivo) is null then
            raise_application_error(c_err_entrada, 'Diga ao escritório por que o depoimento não foi aprovado.');
        end if;
        revisar(p_depoimento_id, 'REPROVADO', p_motivo);
    end reprovar;

    procedure remover(p_depoimento_id in number) is
    begin
        exigir_plataforma;
        delete from depoimento where depoimento_id = p_depoimento_id;
        if sql%rowcount = 0 then
            raise_application_error(c_err_nao_encontrado, 'Depoimento não encontrado.');
        end if;
    end remover;

    function pendentes_qtd return pls_integer is
        l_n pls_integer;
    begin
        select count(*) into l_n from depoimento where status = 'PENDENTE';
        return l_n;
    end pendentes_qtd;
end pkg_ecloud_depoimento;
/
