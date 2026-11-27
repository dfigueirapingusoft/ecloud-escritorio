--------------------------------------------------------------------------------
-- testes/fase2_vitrine.sql
-- Testes offline da vitrine do login (sem HTTP): HTML dos anúncios e dos
-- depoimentos (com escape), contadores de exibição e clique, URL da imagem,
-- permissões e o fluxo de aprovação dos depoimentos.
-- Cria dados de teste e desfaz tudo no final (rollback). Os contadores são
-- gravados em transação autônoma; o teste devolve os valores ao terminar.
--
--   SQL> @db/testes/fase2_vitrine.sql
-- Esperado: todas as linhas "OK" e "fase2_vitrine: SUCESSO".
-- O envio da imagem ao Worker de mídia (HTTP) fica em fase2_integracao.sql.
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set define off

declare
    l_falhas   number := 0;
    l_esc_a    number;
    l_esc_b    number;
    l_anu      number;
    l_casa     number;
    l_dep_a    number;
    l_dep_b    number;
    l_html     clob;
    l_txt      varchar2(4000);
    l_base_ant rtc_config.valor%type;
    l_exib0    number;
    l_cliq0    number;
    l_exib1    number;
    l_cliq1    number;

    procedure confere(p_desc in varchar2, p_ok in boolean) is
    begin
        dbms_output.put_line(case when p_ok then 'OK    ' else 'FALHA ' end || p_desc);
        if not nvl(p_ok, false) then l_falhas := l_falhas + 1; end if;
    end confere;

    function espera_erro(p_sql in varchar2, p_ora in number) return boolean is
    begin
        execute immediate p_sql;
        return false;
    exception
        when others then
            if sqlcode <> p_ora then
                dbms_output.put_line('      (veio ' || sqlerrm || ')');
            end if;
            return sqlcode = p_ora;
    end espera_erro;

    function contem(p_html in clob, p_trecho in varchar2) return boolean is
    begin
        return dbms_lob.instr(p_html, p_trecho) > 0;
    end contem;

    procedure ler_contadores(p_id in number, p_exib out number, p_cliq out number) is
    begin
        select nvl(sum(exibicoes), 0), nvl(sum(cliques), 0) into p_exib, p_cliq
          from anuncio_estatistica
         where anuncio_id = p_id and dia = trunc(sysdate);
    end ler_contadores;

    -- Devolve os contadores do dia ao que eram antes do teste.
    procedure restaurar_contadores(p_id in number, p_exib in number, p_cliq in number) is
        pragma autonomous_transaction;
    begin
        update anuncio_estatistica set exibicoes = p_exib, cliques = p_cliq
         where anuncio_id = p_id and dia = trunc(sysdate);
        delete from anuncio_estatistica
         where anuncio_id = p_id and dia = trunc(sysdate) and exibicoes = 0 and cliques = 0;
        commit;
    end restaurar_contadores;
begin
    savepoint inicio_teste;

    ----------------------------------------------------------------------------
    -- Preparação
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto_sistema;
    insert into escritorio (cnpj, razao_social, nome_fantasia, uf, municipio_ibge)
    values ('11222333000181', 'Escritório A Teste Ltda', 'Contábil A', 'RS', 4314902)
    returning escritorio_id into l_esc_a;
    insert into escritorio (cnpj, razao_social, uf, municipio_ibge)
    values ('12ABC34501DE35', 'Escritório B Teste', 'SP', 3550308)
    returning escritorio_id into l_esc_b;
    insert into usuario (escritorio_id, username, nome, email, perfil)
    values (l_esc_a, 'TESTE_VIT_A', 'Ana <b>Contadora</b>', 'a@teste.local', 'CONTADOR');
    insert into usuario (escritorio_id, username, nome, email, perfil)
    values (l_esc_b, 'TESTE_VIT_B', 'Bruno', 'b@teste.local', 'ADMINISTRADOR');
    insert into usuario (escritorio_id, username, nome, email, perfil, admin_plataforma)
    values (l_esc_a, 'TESTE_VIT_PLAT', 'Plataforma', 'p@teste.local', 'ADMINISTRADOR', 'S');

    select min(anuncio_id) into l_casa from anuncio where patrocinador = 'Ecloud' and exibir_login = 'S';
    select valor into l_base_ant from rtc_config where chave = 'MIDIA_BASE_URL';

    ----------------------------------------------------------------------------
    -- Anúncios: HTML, escape e filtros
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto('TESTE_VIT_PLAT');
    insert into anuncio (patrocinador, chamada, titulo, destaque, texto, etiquetas,
                         botao_rotulo, botao_url, cor_destaque, ordem, exibir_login, exibir_ofertas)
    values ('Parceiro <script>alert(1)</script>', 'Oferta', 'Certificado "A1"', 'com desconto',
            'Texto & detalhes', 'Um; Dois ;;Três', 'Comprar', 'https://parceiro.exemplo/?a=1&b=2',
            '#1C2230', 1, 'S', 'S')
    returning anuncio_id into l_anu;

    pkg_ecloud_ctx.limpar_contexto;  -- tela de login: sem contexto
    l_html := pkg_ecloud_anuncio.login_html;
    confere('login_html traz o carrossel com o anúncio novo', contem(l_html, 'data-ec-ads') and contem(l_html, 'id="ec-ad-' || l_anu || '"'));
    confere('login_html escapa o patrocinador (sem <script>)',
            not contem(l_html, '<script>') and contem(l_html, '&lt;script&gt;'));
    -- APEX_ESCAPE.HTML_ATTRIBUTE codifica também ':' '/' '?' '=' (o navegador decodifica)
    confere('login_html escapa o link no atributo',
            contem(l_html, 'href="' || apex_escape.html_attribute('https://parceiro.exemplo/?a=1&b=2') || '"'));
    confere('etiquetas viram lista sem itens vazios',
            contem(l_html, '<li>Um</li><li>Dois</li><li>Três</li>'));
    confere('ordem: o anúncio de ORDEM 1 é o primeiro e está ativo',
            dbms_lob.instr(l_html, 'id="ec-ad-' || l_anu || '"') < dbms_lob.instr(l_html, 'id="ec-ad-' || l_casa || '"')
            and contem(l_html, 'class="ec-ad is-active" id="ec-ad-' || l_anu || '"'));
    confere('cor escura recebe texto branco', contem(l_html, '--ec-ad-accent:#1C2230;--ec-ad-on-accent:#FFFFFF'));
    confere('sem imagem: órbita decorativa', contem(l_html, 'ec-ad-orbit'));
    confere('mais de um anúncio: pontos de navegação', contem(l_html, 'ec-ads-dots'));
    confere('rótulo "Publicidade"', contem(l_html, '>Publicidade<'));

    l_html := pkg_ecloud_anuncio.ofertas_html;
    confere('ofertas_html traz o parceiro em cartão', contem(l_html, 'ec-ad-card') and contem(l_html, 'data-ad-id="' || l_anu || '"'));
    confere('ofertas_html não traz os anúncios da casa (EXIBIR_OFERTAS = N)', not contem(l_html, 'data-ad-id="' || l_casa || '"'));

    pkg_ecloud_ctx.definir_contexto('TESTE_VIT_PLAT');
    update anuncio set fim_em = trunc(sysdate) - 1, inicio_em = trunc(sysdate) - 10 where anuncio_id = l_anu;
    confere('situação ENCERRADO', pkg_ecloud_anuncio.situacao(l_anu) = 'ENCERRADO');
    confere('encerrado sai do login', not contem(pkg_ecloud_anuncio.login_html, 'ec-ad-' || l_anu || '"'));
    confere('sem parceiros no ar: aviso de lista vazia', contem(pkg_ecloud_anuncio.ofertas_html, 'ec-empty'));
    update anuncio set inicio_em = trunc(sysdate) + 1, fim_em = null where anuncio_id = l_anu;
    confere('situação AGENDADO', pkg_ecloud_anuncio.situacao(l_anu) = 'AGENDADO');
    update anuncio set inicio_em = null, ativo = 'N' where anuncio_id = l_anu;
    confere('situação INATIVO', pkg_ecloud_anuncio.situacao(l_anu) = 'INATIVO');
    update anuncio set ativo = 'S' where anuncio_id = l_anu;
    confere('situação NO_AR', pkg_ecloud_anuncio.situacao(l_anu) = 'NO_AR');

    confere('contraste: amarelo claro recebe grafite', pkg_ecloud_anuncio.cor_contraste('#F5B800') = '#1C2230');
    confere('contraste: azul do Ecloud recebe branco', pkg_ecloud_anuncio.cor_contraste('#1F5FBF') = '#FFFFFF');
    confere('contraste: cor inválida não quebra', pkg_ecloud_anuncio.cor_contraste('xyz') = '#1C2230');

    ----------------------------------------------------------------------------
    -- Imagem: URL pública e permissões (o envio HTTP fica na integração)
    ----------------------------------------------------------------------------
    update anuncio set imagem_chave = 'anuncios/' || l_anu || '/abc.png', imagem_mime = 'image/png', imagem_versao = 3
     where anuncio_id = l_anu;
    update rtc_config set valor = null where chave = 'MIDIA_BASE_URL';
    confere('sem MIDIA_BASE_URL: imagem_url nula (login abre sem imagem)', pkg_ecloud_anuncio.imagem_url(l_anu) is null);
    update rtc_config set valor = 'https://midia.teste' where chave = 'MIDIA_BASE_URL';
    confere('imagem_url = base/objetos/chave?v=versão',
            pkg_ecloud_anuncio.imagem_url(l_anu) = 'https://midia.teste/objetos/anuncios/' || l_anu || '/abc.png?v=3');
    l_html := pkg_ecloud_anuncio.login_html;
    confere('com imagem: <img> no anúncio e sem órbita nele',
            contem(l_html, '<img src="' || apex_escape.html_attribute(
                'https://midia.teste/objetos/anuncios/' || l_anu || '/abc.png?v=3') || '"'));
    confere('imagem_url de anúncio sem imagem é nula', pkg_ecloud_anuncio.imagem_url(l_casa) is null
            or pkg_ecloud_anuncio.imagem_url(l_casa) like 'https://midia.teste/objetos/%');
    confere('salvar_imagem sem arquivo não faz nada', espera_erro(
            'begin pkg_ecloud_anuncio.salvar_imagem(' || l_anu || ', null); raise_application_error(-20999, ''ok''); end;', -20999));

    pkg_ecloud_ctx.definir_contexto('TESTE_VIT_A');
    confere('usuário de escritório não envia imagem (ORA-20121)',
        espera_erro('begin pkg_ecloud_anuncio.salvar_imagem(' || l_anu || ', ''x.png''); end;', -20121));
    confere('usuário de escritório não remove imagem (ORA-20121)',
        espera_erro('begin pkg_ecloud_anuncio.remover_imagem(' || l_anu || '); end;', -20121));

    ----------------------------------------------------------------------------
    -- Contadores (anúncio da casa, já gravado: a transação autônoma o enxerga)
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.limpar_contexto;
    ler_contadores(l_casa, l_exib0, l_cliq0);
    pkg_ecloud_anuncio.registrar_evento(l_casa, 'EXIBICAO');
    pkg_ecloud_anuncio.registrar_evento(l_casa, 'exibicao');
    pkg_ecloud_anuncio.registrar_evento(l_casa, 'CLIQUE');      -- sem link: não conta
    pkg_ecloud_anuncio.registrar_evento(l_casa, 'OUTRO');       -- ignorado
    pkg_ecloud_anuncio.registrar_evento(-1, 'EXIBICAO');        -- inexistente: ignorado
    ler_contadores(l_casa, l_exib1, l_cliq1);
    confere('duas exibições somadas na página pública', l_exib1 = l_exib0 + 2);
    confere('clique em anúncio sem link não conta', l_cliq1 = l_cliq0);
    confere('registrar_clique sem link devolve nulo', pkg_ecloud_anuncio.registrar_clique(l_casa) is null);
    l_txt := pkg_ecloud_anuncio.estatistica_rotulo(l_casa);
    confere('estatistica_rotulo: "' || l_txt || '"', l_txt like '%exibiç%' and l_txt like '%clique%');
    restaurar_contadores(l_casa, l_exib0, l_cliq0);
    ler_contadores(l_casa, l_exib1, l_cliq1);
    confere('contadores devolvidos ao valor anterior', l_exib1 = l_exib0 and l_cliq1 = l_cliq0);

    ----------------------------------------------------------------------------
    -- Depoimentos: escrever, aprovar, reprovar, login
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto('TESTE_VIT_A');
    confere('meu_id nulo antes de escrever', pkg_ecloud_depoimento.meu_id is null);
    confere('sugestao_autor = nome do usuário', pkg_ecloud_depoimento.sugestao_autor = 'Ana <b>Contadora</b>');
    confere('sugestao_escritorio = nome fantasia', pkg_ecloud_depoimento.sugestao_escritorio = 'Contábil A');
    confere('sugestao_cidade termina com a UF', pkg_ecloud_depoimento.sugestao_cidade like '%RS');
    confere('convite quando ainda não escreveu', pkg_ecloud_depoimento.situacao_html(null) like '%ec-notice--info%');
    confere('texto curto é recusado (ORA-20130)', espera_erro(
        q'[begin pkg_ecloud_depoimento.salvar_meu('Ana', null, 'Contábil A', null, 'curto', 5); end;]', -20130));
    confere('nota 6 é recusada (ORA-20130)', espera_erro(
        q'[begin pkg_ecloud_depoimento.salvar_meu('Ana', null, 'Contábil A', null, 'Texto com mais de vinte letras.', 6); end;]', -20130));

    pkg_ecloud_depoimento.salvar_meu(pkg_ecloud_depoimento.sugestao_autor, 'Sócia', pkg_ecloud_depoimento.sugestao_escritorio,
                                     'Porto Alegre/RS', 'As simulações da Reforma <ficaram> rápidas & claras.', 4);
    l_dep_a := pkg_ecloud_depoimento.meu_id;
    confere('salvar_meu cria o depoimento do usuário', l_dep_a is not null);
    confere('nasce aguardando aprovação', pkg_ecloud_depoimento.situacao_html(l_dep_a) like '%ec-notice--warning%');
    confere('A não aprova (ORA-20132)', espera_erro('begin pkg_ecloud_depoimento.aprovar(' || l_dep_a || '); end;', -20132));
    confere('A não remove pela rotina da plataforma (ORA-20132)',
        espera_erro('begin pkg_ecloud_depoimento.remover(' || l_dep_a || '); end;', -20132));

    pkg_ecloud_ctx.definir_contexto('TESTE_VIT_B');
    pkg_ecloud_depoimento.salvar_meu('Bruno', null, 'Escritório B', null, 'O DANFSe sai em segundos, sem retrabalho.', 5);
    l_dep_b := pkg_ecloud_depoimento.meu_id;

    pkg_ecloud_ctx.limpar_contexto;
    confere('pendentes não aparecem no login', pkg_ecloud_depoimento.login_html is null
            or not contem(pkg_ecloud_depoimento.login_html, 'ec-quote-' || l_dep_a || '"'));

    pkg_ecloud_ctx.definir_contexto('TESTE_VIT_PLAT');
    confere('pendentes_qtd conta os dois', pkg_ecloud_depoimento.pendentes_qtd >= 2);
    pkg_ecloud_depoimento.aprovar(l_dep_a);
    confere('reprovar sem motivo é recusado (ORA-20130)',
        espera_erro('begin pkg_ecloud_depoimento.reprovar(' || l_dep_b || ', ''  ''); end;', -20130));
    pkg_ecloud_depoimento.reprovar(l_dep_b, 'Cite o <nome> do recurso que mais ajudou.');
    confere('aprovar inexistente (ORA-20131)', espera_erro('begin pkg_ecloud_depoimento.aprovar(-1); end;', -20131));

    pkg_ecloud_ctx.limpar_contexto;
    l_html := pkg_ecloud_depoimento.login_html;
    confere('aprovado aparece no login', contem(l_html, 'id="ec-quote-' || l_dep_a || '"'));
    confere('reprovado não aparece no login', not contem(l_html, 'ec-quote-' || l_dep_b || '"'));
    confere('texto do depoimento escapado', contem(l_html, '&lt;ficaram&gt; rápidas &amp; claras'));
    confere('autor escapado e avatar com a inicial', contem(l_html, apex_escape.html('Ana <b>Contadora</b>'))
            and not contem(l_html, '<b>')
            and contem(l_html, 'ec-quote-avatar" aria-hidden="true">A<'));
    confere('cargo, escritório e cidade', contem(l_html, 'Sócia, Contábil A · ' || apex_escape.html('Porto Alegre/RS')));
    confere('4 estrelas com 1 apagada', contem(l_html, 'aria-label="4 de 5 estrelas">★★★★<span class="ec-quote-stars-off">★</span>'));

    pkg_ecloud_ctx.definir_contexto('TESTE_VIT_B');
    l_txt := pkg_ecloud_depoimento.situacao_html(l_dep_b);
    confere('B vê o motivo da reprovação escapado', l_txt like '%ec-notice--danger%' and l_txt like '%&lt;nome&gt;%');
    pkg_ecloud_depoimento.salvar_meu('Bruno', null, 'Escritório B', null, 'O DANFSe sai em segundos e o PDF já vem pronto.', 5);
    confere('reenviar volta para aguardando', pkg_ecloud_depoimento.situacao_html(l_dep_b) like '%ec-notice--warning%');

    pkg_ecloud_ctx.definir_contexto('TESTE_VIT_A');
    confere('aprovado mostra aviso de sucesso', pkg_ecloud_depoimento.situacao_html(l_dep_a) like '%ec-notice--success%');
    pkg_ecloud_depoimento.salvar_meu('Ana', 'Sócia', 'Contábil A', 'Porto Alegre/RS',
                                     'Mudei o texto do meu depoimento aprovado.', 5);
    confere('mudar o aprovado volta para aguardando', pkg_ecloud_depoimento.situacao_html(l_dep_a) like '%ec-notice--warning%');
    pkg_ecloud_depoimento.excluir_meu;
    confere('excluir_meu apaga o próprio', pkg_ecloud_depoimento.meu_id is null);

    pkg_ecloud_ctx.definir_contexto('TESTE_VIT_PLAT');
    pkg_ecloud_depoimento.remover(l_dep_b);
    confere('plataforma remove depoimento de outro escritório (ORA-20131 na segunda vez)',
        espera_erro('begin pkg_ecloud_depoimento.remover(' || l_dep_b || '); end;', -20131));

    pkg_ecloud_ctx.limpar_contexto;
    confere('sem escritório não escreve depoimento (ORA-20132)', espera_erro(
        q'[begin pkg_ecloud_depoimento.salvar_meu('X', null, 'X', null, 'Texto com mais de vinte letras.', 5); end;]', -20132));

    ----------------------------------------------------------------------------
    -- Limpeza
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.limpar_contexto;
    rollback to inicio_teste;

    if l_falhas = 0 then
        dbms_output.put_line('fase2_vitrine: SUCESSO');
    else
        raise_application_error(-20999, 'fase2_vitrine: ' || l_falhas || ' falha(s)');
    end if;
exception
    when others then
        pkg_ecloud_ctx.limpar_contexto;
        rollback to inicio_teste;
        raise;
end;
/
