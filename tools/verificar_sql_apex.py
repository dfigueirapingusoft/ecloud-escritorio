# tools/verificar_sql_apex.py
# Extrai os trechos SQL e PL/SQL do app APEXlang (apex/) e gera um script que
# faz DBMS_SQL.PARSE de cada um no schema da aplicação. O apexlang-compile valida
# a sintaxe APEXlang offline, mas não confere tabelas, colunas e pacotes.
#   python3 tools/verificar_sql_apex.py /tmp/verificar.sql && sql ECLOUD@base @/tmp/verificar.sql
# Esperado: "Trechos OK: N, com erro: 0".
import re, glob, os, sys

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'apex')
SAIDA = sys.argv[1] if len(sys.argv) > 1 else 'verificar_sql_apex.sql'
trechos = []
for f in sorted(glob.glob(APP + '/**/*.apx', recursive=True)):
    rel = os.path.relpath(f, APP)
    lines = open(f).read().split('\n')
    i = 0
    while i < len(lines):
        l = lines[i]
        m = re.match(r'\s*(\w+):\s*$', l)
        if m and i + 1 < len(lines) and re.match(r'\s*```(\w*)\s*$', lines[i + 1]):
            prop = m.group(1)
            lang = re.match(r'\s*```(\w*)', lines[i + 1]).group(1)
            j = i + 2
            body = []
            while not re.match(r'\s*```\s*$', lines[j]):
                body.append(lines[j])
                j += 1
            txt = '\n'.join(body)
            # remove indentação comum
            ind = min((len(x) - len(x.lstrip()) for x in body if x.strip()), default=0)
            txt = '\n'.join(x[ind:] for x in body)
            trechos.append((rel, i + 1, prop, lang, txt))
            i = j + 1
            continue
        m = re.match(r'\s*(sqlQuery|plsqlExpression|plsqlFunctionBody|plsqlCode|sqlQuerySingleValue|initPlsqlCode|cleanupPlsqlCode):\s*(\S.*)$', l)
        if m:
            trechos.append((rel, i + 1, m.group(1), '', m.group(2)))
        i += 1

out = ['set serveroutput on size unlimited', 'set define off', 'declare',
       '    l_c integer;', '    l_err number := 0;', '    l_ok number := 0;',
       '    procedure t(p_onde varchar2, p_sql clob) is',
       '    begin',
       '        l_c := dbms_sql.open_cursor;',
       '        dbms_sql.parse(l_c, p_sql, dbms_sql.native);',
       '        dbms_sql.close_cursor(l_c);',
       '        l_ok := l_ok + 1;',
       '    exception when others then',
       '        if dbms_sql.is_open(l_c) then dbms_sql.close_cursor(l_c); end if;',
       "        l_err := l_err + 1;",
       "        dbms_output.put_line('ERRO ' || p_onde || ': ' || sqlerrm);",
       '    end;',
       '    -- function body: vale se compilar retornando boolean ou texto',
       '    procedure t2(p_onde varchar2, p_bool clob, p_texto clob) is',
       '    begin',
       '        l_c := dbms_sql.open_cursor;',
       '        dbms_sql.parse(l_c, p_bool, dbms_sql.native);',
       '        dbms_sql.close_cursor(l_c);',
       '        l_ok := l_ok + 1;',
       '    exception when others then',
       '        if dbms_sql.is_open(l_c) then dbms_sql.close_cursor(l_c); end if;',
       '        t(p_onde, p_texto);',
       '    end;', 'begin']
# Bloco PL/SQL com bind não é compilado no PARSE (só na execução). Para o bloco
# ser compilado de fato, cada bind de item (:P1_X, :F_X, :APP_X) vira variável local.
BIND = re.compile(r':((?:P\d+|F|APP)_[A-Z0-9_]+)')


def com_variaveis(sql, t_original):
    nomes = sorted(set(BIND.findall(t_original)))
    if not nomes:
        return sql
    decl = ''.join(f'b_{n} varchar2(32767); ' for n in nomes)
    sql = BIND.sub(lambda m: 'b_' + m.group(1), sql)
    return f'declare {decl}\nbegin\n{sql}\nend;'


for rel, ln, prop, lang, txt in trechos:
    onde = f'{rel}:{ln} {prop}'
    t = txt.strip()
    if prop in ('sqlQuery', 'sqlQuerySingleValue') or lang == 'sql':
        sql = t
    elif prop == 'plsqlExpression':
        sql = f'declare x varchar2(32767); b boolean; begin\n-- {onde}\nif false then x := ({t}); end if;\nexception when others then null; end;'
        # tenta como booleano se falhar como texto: gera as duas versões
        sql_b = f'declare b boolean; begin if ({t}) then null; end if; end;'
        sql, sql_b = com_variaveis(sql, t), com_variaveis(sql_b, t)
        out.append(f"    begin t('{onde} (bool)', q'~{sql_b}~'); end;") if any(w in t for w in (' is not null', ' is null', '<>', ' and ', 'not ', 'is_admin', 'persistent_cookies')) else out.append(f"    t('{onde}', q'~{sql}~');")
        continue
    elif prop == 'plsqlFunctionBody':
        sql_b = com_variaveis(f'declare function f return boolean is begin\n{t}\nend; begin null; end;', t)
        sql = com_variaveis(f'declare function f return varchar2 is begin\n{t}\nend; begin null; end;', t)
        out.append(f"    t2('{onde}', q'~{sql_b}~', q'~{sql}~');")
        continue
    elif prop in ('plsqlCode', 'initPlsqlCode', 'cleanupPlsqlCode'):
        if re.sub(r'(?m)^\s*--.*\n', '', t).lstrip().lower().startswith('procedure'):
            sql = f'declare\n{t}\nbegin null; end;'
        elif t.lstrip().lower().startswith('declare') or t.lstrip().lower().startswith('begin'):
            sql = t if t.rstrip().endswith(';') else t + ';'
        else:
            sql = f'begin\n{t}\nend;'
    else:
        continue
    if not (prop in ('sqlQuery', 'sqlQuerySingleValue') or lang == 'sql'):
        sql = com_variaveis(sql, t)
    out.append(f"    t('{onde}', q'~{sql}~');")
out += ["    dbms_output.put_line('Trechos OK: ' || l_ok || ', com erro: ' || l_err);", 'end;', '/']
open(SAIDA, 'w').write('\n'.join(out) + '\n')
print(f'{len(trechos)} trechos -> {SAIDA}. Rode: sql ECLOUD@base @{SAIDA}')
