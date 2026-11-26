--------------------------------------------------------------------------------
-- testes/fase2_offline.sql
-- Testes dos pacotes SEM chamadas HTTP: utilitários, montagem do JSON de
-- entrada, leitura das respostas reais das calculadoras (copiadas de
-- docs/contratos/exemplos-respostas.txt), ProblemDetail 422, mensagens
-- amigáveis e validação do XML do DANFSe.
-- Cria dados de teste e desfaz tudo no final (rollback).
--
--   SQL> @db/testes/fase2_offline.sql
-- Esperado: todas as linhas "OK" e "fase2_offline: SUCESSO".
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set define off
-- separador decimal vírgula de propósito: a leitura não pode depender de NLS
alter session set nls_numeric_characters = ',.';

declare
    l_falhas  number := 0;
    l_esc     number;
    l_cli     number;
    l_cli_sn  number;
    l_sim     number;
    l_sim_sn  number;
    l_sim_422 number;
    l_qtd     number;
    l_txt     varchar2(4000);
    l_req     clob;
    l_s       simulacao%rowtype;
    l_i       simulacao_item%rowtype;
    l_val     pkg_rtc_danfse.t_validacao;

    c_resp_regime  constant clob := q'~{
 "objetos": [
  {
   "nObj": 1,
   "estadoItem": "CALCULO_SIMULADO",
   "tribCalc": {
    "IBSCBS": {
     "CST": "200",
     "cClassTrib": "200003",
     "gIBSCBS": {
      "vBC": "100.00",
      "gIBSUF": {
       "pIBSUF": "0.05",
       "gRed": {
        "pRedAliq": "100.00",
        "pAliqEfet": "0.00"
       },
       "vIBSUF": "0.00"
      },
      "gIBSMun": {
       "pIBSMun": "0.05",
       "gRed": {
        "pRedAliq": "100.00",
        "pAliqEfet": "0.00"
       },
       "vIBSMun": "0.00"
      },
      "vIBS": "0.00",
      "gCBS": {
       "pCBS": "8.80",
       "gRed": {
        "pRedAliq": "100.00",
        "pAliqEfet": "0.00"
       },
       "vCBS": "0.00"
      }
     },
     "memoriaCalculo": {
      "cbs": "Operação de consumo com enquadramento legal em Art. 125, tributada conforme Alíquota zero. A base de cálculo utilizada é de R$ 100,00, com alíquota de zero.",
      "ibsUF": "Operação de consumo com enquadramento legal em Art. 125, tributada conforme Alíquota zero. A base de cálculo utilizada é de R$ 100,00, com alíquota de zero.",
      "ibsMun": "Operação de consumo com enquadramento legal em Art. 125, tributada conforme Alíquota zero. A base de cálculo utilizada é de R$ 100,00, com alíquota de zero."
     }
    }
   }
  },
  {
   "nObj": 2,
   "estadoItem": "CALCULO_SIMULADO",
   "tribCalc": {
    "IS": {
     "CSTIS": "000",
     "cClassTribIS": "000001",
     "vBCIS": "150.00",
     "pIS": "10.00",
     "uTrib": "LT",
     "qTrib": "12",
     "vIS": "15.00",
     "memoriaCalculo": "Operação de consumo sujeita à tributação pelo Imposto Seletivo, com enquadramento legal em Art. 412, I, tributada conforme Tributação pelo Imposto Seletivo - Com Cálculo. A base de cálculo utilizada é de R$ 150,00, com alíquota ad valorem de 10,00%. A alíquota ad rem é de 0,00."
    },
    "IBSCBS": {
     "CST": "000",
     "cClassTrib": "000001",
     "gIBSCBS": {
      "vBC": "165.00",
      "gIBSUF": {
       "pIBSUF": "0.05",
       "vIBSUF": "0.08"
      },
      "gIBSMun": {
       "pIBSMun": "0.05",
       "vIBSMun": "0.08"
      },
      "vIBS": "0.16",
      "gCBS": {
       "pCBS": "8.80",
       "vCBS": "14.52"
      }
     },
     "memoriaCalculo": {
      "cbs": "Operação de consumo com enquadramento legal em LC 214/2025, tributada conforme Tributação integral. A base de cálculo utilizada é de R$ 165,00, com alíquota de 8,80%.",
      "ibsUF": "Operação de consumo com enquadramento legal em LC 214/2025, tributada conforme Tributação integral. A base de cálculo utilizada é de R$ 165,00, com alíquota de 0,05%.",
      "ibsMun": "Operação de consumo com enquadramento legal em LC 214/2025, tributada conforme Tributação integral. A base de cálculo utilizada é de R$ 165,00, com alíquota de 0,05%."
     }
    }
   }
  },
  {
   "nObj": 3,
   "estadoItem": "CALCULO_SIMULADO",
   "tribCalc": {
    "IBSCBS": {
     "CST": "200",
     "cClassTrib": "200028",
     "gIBSCBS": {
      "vBC": "1200.00",
      "gIBSUF": {
       "pIBSUF": "0.05",
       "gRed": {
        "pRedAliq": "60.00",
        "pAliqEfet": "0.02"
       },
       "vIBSUF": "0.24"
      },
      "gIBSMun": {
       "pIBSMun": "0.05",
       "gRed": {
        "pRedAliq": "60.00",
        "pAliqEfet": "0.02"
       },
       "vIBSMun": "0.24"
      },
      "vIBS": "0.48",
      "gCBS": {
       "pCBS": "8.80",
       "gRed": {
        "pRedAliq": "60.00",
        "pAliqEfet": "3.52"
       },
       "vCBS": "42.24"
      }
     },
     "memoriaCalculo": {
      "cbs": "Operação de consumo com enquadramento legal em Art. 129, tributada conforme Alíquota reduzida em 60%. A base de cálculo utilizada é de R$ 1.200,00, com alíquota de 8,80%, sendo que esse regime define uma redução de 60,00% na alíquota.",
      "ibsUF": "Operação de consumo com enquadramento legal em Art. 129, tributada conforme Alíquota reduzida em 60%. A base de cálculo utilizada é de R$ 1.200,00, com alíquota de 0,05%, sendo que esse regime define uma redução de 60,00% na alíquota.",
      "ibsMun": "Operação de consumo com enquadramento legal em Art. 129, tributada conforme Alíquota reduzida em 60%. A base de cálculo utilizada é de R$ 1.200,00, com alíquota de 0,05%, sendo que esse regime define uma redução de 60,00% na alíquota."
     }
    }
   }
  },
  {
   "nObj": 4,
   "estadoItem": "INCONSISTENCIA_ENTRADA",
   "erros": [
    {
     "type": "http://localhost/api/calculadora/observabilidade/erros?codigo=REG-011",
     "title": "NCM não vinculada",
     "code": "REG-011",
     "pointer": "#/itens/3/ncm",
     "detail": "NCM de código 02013000 não vinculada à Classificação Tributária de código 200035 (CBS e IBS)"
    }
   ]
  }
 ],
 "total": {
  "tribCalc": {
   "ISTot": {
    "vIS": "15.00"
   },
   "IBSCBSTot": {
    "vBCIBSCBS": "1465.00",
    "gIBS": {
     "gIBSUF": {
      "vDif": "0.00",
      "vDevTrib": "0.00",
      "vIBSUF": "0.32"
     },
     "gIBSMun": {
      "vDif": "0.00",
      "vDevTrib": "0.00",
      "vIBSMun": "0.32"
     },
     "vIBS": "0.64",
     "vCredPres": "0.00",
     "vCredPresCondSus": "0.00"
    },
    "gCBS": {
     "vDif": "0.00",
     "vDevTrib": "0.00",
     "vCBS": "56.76",
     "vCredPres": "0.00",
     "vCredPresCondSus": "0.00"
    },
    "gMono": {
     "vIBSMono": "0.00",
     "vCBSMono": "0.00",
     "vIBSMonoReten": "0.00",
     "vCBSMonoReten": "0.00",
     "vIBSMonoRet": "0.00",
     "vCBSMonoRet": "0.00"
    }
   }
  }
 }
}~';
    c_resp_simples constant clob := q'~{
 "oper": {
  "data": "2027-03-15",
  "tpDoc": "55",
  "CRT": "1"
 },
 "objetos": [
  {
   "nObj": 1,
   "estadoItem": "CALCULADO",
   "tribCalc": {
    "vRBSNitem": "950.00",
    "tpRBSN": 1,
    "tpRBSNDescricao": "Receita bruta - interna",
    "vBC": "950.00",
    "pIBSSN": "1.25",
    "vIBSSN": "11.88",
    "vIBSPendSusp": "0.00",
    "pCBSSN": "2.75",
    "vCBSSN": "26.12",
    "vCBSPendSusp": "0.00",
    "IS": {
     "valor": "50.00"
    },
    "totalItem": "88.00",
    "memoriaCalculo": {
     "cbs": "Receita bruta do Simples Nacional de R$ 950,00 (Receita bruta - interna). A base de cálculo utilizada é de R$ 950,00, com alíquota efetiva de 2,75%. Valor devido de R$ 26,12 e pendente/suspenso de R$ 0,00.",
     "ibs": "Receita bruta do Simples Nacional de R$ 950,00 (Receita bruta - interna). A base de cálculo utilizada é de R$ 950,00, com alíquota efetiva de 1,25%. Valor devido de R$ 11,88 e pendente/suspenso de R$ 0,00."
    }
   }
  },
  {
   "nObj": 2,
   "estadoItem": "NAO_CALCULADO",
   "motivoEstado": {
    "codigo": "CATIVSN_DESCONHECIDO",
    "descricao": "O código de atividade '99' não existe ou não está vigente na data do fato gerador; o IBS e a CBS do item não são calculados."
   },
   "tribCalc": {
    "vRBSNitem": "100.00",
    "tpRBSN": 1,
    "tpRBSNDescricao": "Receita bruta - interna"
   }
  },
  {
   "nObj": 3,
   "estadoItem": "INCONSISTENCIA_ENTRADA",
   "erros": [
    {
     "type": "http://localhost/calculadora/observabilidade/simples-nacional/erros?codigo=VSN-051",
     "title": "Formato de nomenclatura inválido",
     "code": "VSN-051",
     "pointer": "#/itens/2/ncm",
     "detail": "O NCM deve conter exclusivamente 8 dígitos ASCII, sem espaços ou símbolos."
    }
   ]
  }
 ],
 "total": {
  "vRBSNtot": "1050.00",
  "vBC": "950.00",
  "vIBSSNtot": "11.88",
  "vIBSSNtotPendSusp": "0.00",
  "vCBSSNtot": "26.12",
  "vCBSSNtotPendSusp": "0.00",
  "totalIs": "50.00",
  "totalTributos": "88.00"
 }
}~';
    c_resp_422     constant clob := q'~{
 "detail": "O cálculo contém 1 erro(s).",
 "instance": "/api/calculadora/observabilidade/regime-geral",
 "status": 422,
 "title": "Erros no processamento do cálculo",
 "type": "about:blank",
 "timestamp": "2026-11-26T13:11:30.892771343Z",
 "errors": [
  {
   "type": "http://localhost/api/calculadora/observabilidade/erros?codigo=REG-020",
   "title": "UF não encontrada",
   "code": "REG-020",
   "pointer": "#/itens/-1",
   "detail": "UF de sigla XX não encontrada"
  }
 ]
}~';
    c_req_regime   constant clob := q'~{
 "id": "6194602ea71cbf9431c236de4409d920",
 "versao": "1.0.0",
 "dhFatoGerador": "2027-03-10T10:00:00-03:00",
 "municipio": 4314902,
 "uf": "RS",
 "itens": [
  {
   "numero": 1,
   "ncm": "10063021",
   "cst": "200",
   "cClassTrib": "200003",
   "baseCalculo": 100.0,
   "quantidade": 20,
   "unidade": "KG",
   "aliquotasNominais": {
    "cbs": 8.8,
    "ibsEstadual": 0.05,
    "ibsMunicipal": 0.05
   }
  },
  {
   "numero": 2,
   "ncm": "22030000",
   "cst": "000",
   "cClassTrib": "000001",
   "quantidade": 12,
   "unidade": "LT",
   "impostoSeletivo": {
    "cst": "000",
    "cClassTrib": "000001",
    "baseCalculo": 150.0,
    "quantidade": 12,
    "unidade": "LT",
    "impostoInformado": 15.0
   },
   "aliquotasNominais": {
    "cbs": 8.8,
    "ibsEstadual": 0.05,
    "ibsMunicipal": 0.05,
    "impostoSeletivo": {
     "adValorem": 10.0
    }
   }
  },
  {
   "numero": 3,
   "nbs": "122011200",
   "cst": "200",
   "cClassTrib": "200028",
   "baseCalculo": 1200.0,
   "aliquotasNominais": {
    "cbs": 8.8,
    "ibsEstadual": 0.05,
    "ibsMunicipal": 0.05
   }
  },
  {
   "numero": 4,
   "ncm": "02013000",
   "cst": "200",
   "cClassTrib": "200035",
   "baseCalculo": 80.0,
   "aliquotasNominais": {
    "cbs": 8.8,
    "ibsEstadual": 0.05,
    "ibsMunicipal": 0.05
   }
  }
 ]
}~';
    c_req_simples  constant clob := q'~{
 "id": "507f1f77bcf86cd799439011",
 "versao": "2.0.0",
 "data": "2027-03-15",
 "tpDoc": "55",
 "CRT": "1",
 "itens": [
  {
   "numero": 1,
   "cAtivSN": "01",
   "cClassTrib": "000001",
   "ncm": "22030000",
   "baseCalculo": "950.00",
   "valorImpostoSeletivo": "50.00",
   "pIBSSN": "1.25",
   "pCBSSN": "2.75"
  },
  {
   "numero": 2,
   "cAtivSN": "99",
   "cClassTrib": "000001",
   "ncm": "10063021",
   "baseCalculo": "100.00",
   "valorImpostoSeletivo": "0.00",
   "pIBSSN": "1.25",
   "pCBSSN": "2.75"
  },
  {
   "numero": 3,
   "cAtivSN": "01",
   "cClassTrib": "000001",
   "ncm": "10063021",
   "baseCalculo": "100.00",
   "valorImpostoSeletivo": "0.00",
   "pIBSSN": "1.25",
   "pCBSSN": "2.75"
  }
 ]
}~';

    procedure confere(p_desc in varchar2, p_ok in boolean) is
    begin
        dbms_output.put_line(case when p_ok then 'OK    ' else 'FALHA ' end || p_desc);
        if p_ok is null or not p_ok then l_falhas := l_falhas + 1; end if;
    end confere;

    function item(p_sim in number, p_num in number) return simulacao_item%rowtype is
        l simulacao_item%rowtype;
    begin
        select * into l from simulacao_item where simulacao_id = p_sim and numero = p_num;
        return l;
    end item;

    function sim(p_sim in number) return simulacao%rowtype is
        l simulacao%rowtype;
    begin
        select * into l from simulacao where simulacao_id = p_sim;
        return l;
    end sim;

    function blob_de(p_txt in varchar2) return blob is
    begin
        return utl_raw.cast_to_raw(convert(p_txt, 'AL32UTF8'));
    end blob_de;
begin
    savepoint inicio_teste;

    ----------------------------------------------------------------------------
    -- PKG_ECLOUD_UTIL
    ----------------------------------------------------------------------------
    confere('CNPJ alfanumérico 12ABC34501DE35 válido', pkg_ecloud_util.cnpj_valido('12.ABC.345/01DE-35'));
    confere('CNPJ numérico 11.222.333/0001-81 válido', pkg_ecloud_util.cnpj_valido('11.222.333/0001-81'));
    confere('CNPJ com DV errado inválido', not pkg_ecloud_util.cnpj_valido('11222333000182'));
    confere('CNPJ repetido inválido', not pkg_ecloud_util.cnpj_valido('00000000000000'));
    confere('formatar CNPJ', pkg_ecloud_util.formatar_cnpj('12abc34501de35') = '12.ABC.345/01DE-35');
    confere('para_numero("1200.00") com NLS vírgula', pkg_ecloud_util.para_numero('1200.00') = 1200);
    confere('para_numero("-0.5")', pkg_ecloud_util.para_numero('-0.5') = -0.5);
    confere('para_numero inválido = nulo', pkg_ecloud_util.para_numero('abc') is null);
    confere('para_decimal_api(950, 2) = "950.00"', pkg_ecloud_util.para_decimal_api(950, 2) = '950.00');
    confere('para_decimal_api(1.25, null) = "1.25"', pkg_ecloud_util.para_decimal_api(1.25, null) = '1.25');
    confere('para_decimal_api(0.5, null) = "0.5"', pkg_ecloud_util.para_decimal_api(0.5, null) = '0.5');
    confere('para_decimal_api(3, null) = "3"', pkg_ecloud_util.para_decimal_api(3, null) = '3');
    confere('para_iso8601', pkg_ecloud_util.para_iso8601(timestamp '2027-03-10 10:00:00 -03:00') = '2027-03-10T10:00:00-03:00');

    ----------------------------------------------------------------------------
    -- Dados de teste (contexto de sistema restrito ao escritório criado)
    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.definir_contexto_sistema;
    insert into escritorio (cnpj, razao_social, uf, municipio_ibge)
    values ('12ABC34501DE35', 'Escritório Teste Fase 2', 'RS', 4314902)
    returning escritorio_id into l_esc;
    pkg_ecloud_ctx.definir_contexto_sistema(l_esc);

    insert into cliente (cnpj, razao_social, uf, municipio_ibge, regime)
    values ('11222333000181', 'Cliente Regime', 'RS', 4314902, 'REGULAR') returning cliente_id into l_cli;
    insert into cliente (cnpj, razao_social, uf, municipio_ibge, regime, crt)
    values ('11444777000161', 'Cliente Simples', 'RS', 4314902, 'SIMPLES', '1') returning cliente_id into l_cli_sn;

    -- catálogo prévio: evita chamadas HTTP neste teste
    merge into rtc_erro_catalogo d
    using (select 'REG-011' codigo, 'REGIME' servico, 'NCM não vinculada' titulo, null msg from dual union all
           select 'REG-020', 'REGIME', 'UF não encontrada', 'Confira a UF da operação.' from dual union all
           select 'VSN-051', 'SIMPLES', 'Formato de nomenclatura inválido', null from dual) o
       on (d.codigo = o.codigo)
     when matched then update set d.mensagem_amigavel = o.msg, d.encontrado_api = 'S'
     when not matched then insert (codigo, servico, titulo, mensagem_amigavel, encontrado_api, sincronizado_em)
                           values (o.codigo, o.servico, o.titulo, o.msg, 'S', systimestamp);

    ----------------------------------------------------------------------------
    -- Regime Regular: montagem do JSON (mesma operação de exemplos-respostas.txt)
    ----------------------------------------------------------------------------
    insert into simulacao (cliente_id, regime, id_operacao, versao_leiaute, dh_fato_gerador, uf, municipio_ibge)
    values (l_cli, 'REGULAR', '6194602ea71cbf9431c236de4409d920', '1.0.0',
            timestamp '2027-03-10 10:00:00 -03:00', 'RS', 4314902)
    returning simulacao_id into l_sim;
    insert into simulacao_item (simulacao_id, numero, ncm, cst, cclasstrib, base_calculo, quantidade, unidade,
                                aliq_cbs, aliq_ibs_uf, aliq_ibs_mun)
    values (l_sim, 1, '10063021', '200', '200003', 100, 20, 'KG', 8.8, 0.05, 0.05);
    insert into simulacao_item (simulacao_id, numero, ncm, cst, cclasstrib, quantidade, unidade,
                                is_cst, is_cclasstrib, is_base_calculo, is_quantidade, is_unidade, is_imposto_informado,
                                aliq_cbs, aliq_ibs_uf, aliq_ibs_mun, aliq_is_ad_valorem)
    values (l_sim, 2, '22030000', '000', '000001', 12, 'LT', '000', '000001', 150, 12, 'LT', 15, 8.8, 0.05, 0.05, 10);
    insert into simulacao_item (simulacao_id, numero, nbs, cst, cclasstrib, base_calculo, aliq_cbs, aliq_ibs_uf, aliq_ibs_mun)
    values (l_sim, 3, '122011200', '200', '200028', 1200, 8.8, 0.05, 0.05);
    insert into simulacao_item (simulacao_id, numero, ncm, cst, cclasstrib, base_calculo, aliq_cbs, aliq_ibs_uf, aliq_ibs_mun)
    values (l_sim, 4, '02013000', '200', '200035', 80, 8.8, 0.05, 0.05);

    l_req := pkg_rtc_calc.montar_requisicao_regime(l_sim);
    select count(*) into l_qtd from dual where json_equal(l_req, c_req_regime);
    confere('JSON do Regime igual ao exemplo oficial (JSON_EQUAL)', l_qtd = 1);
    confere('Regime: item com NBS não leva "ncm"', not json_exists(l_req, '$.itens[2].ncm'));
    confere('Regime: sem gCompraGov quando não informado', not json_exists(l_req, '$.gCompraGov'));

    ----------------------------------------------------------------------------
    -- Regime Regular: leitura da resposta real
    ----------------------------------------------------------------------------
    pkg_rtc_calc.processar_resposta_regime(l_sim, c_resp_regime, 6);
    l_s := sim(l_sim);
    confere('Regime: status PROCESSADA_COM_PENDENCIAS', l_s.status = 'PROCESSADA_COM_PENDENCIAS');
    confere('Regime: 4 itens, 1 pendente', l_s.qtd_itens = 4 and l_s.qtd_itens_pendentes = 1);
    confere('Regime: totais vBC 1465,00 / IBS 0,64 / CBS 56,76 / IS 15,00',
            l_s.tot_base_calculo = 1465 and l_s.tot_ibs = 0.64 and l_s.tot_cbs = 56.76 and l_s.tot_is = 15);
    confere('Regime: total de tributos 72,40', l_s.tot_tributos = 72.40);
    confere('Regime: x-warning-dados-simulados = 6', l_s.warning_dados_simulados = 6);
    l_i := item(l_sim, 3);
    confere('Regime item 3: CALCULO_SIMULADO, vBC 1200, redução 60%, CBS 42,24',
            l_i.estado_item = 'CALCULO_SIMULADO' and l_i.r_vbc = 1200 and l_i.r_p_red_aliq = 60 and l_i.r_v_cbs = 42.24);
    confere('Regime item 3: alíquota efetiva CBS 3,52 e IBS 0,48', l_i.r_p_aliq_efet_cbs = 3.52 and l_i.r_v_ibs = 0.48);
    confere('Regime item 3: memória de cálculo gravada', dbms_lob.instr(l_i.r_memoria_calculo, 'CBS: ') = 1);
    confere('Regime item 3: tribCalc completo gravado', json_value(l_i.r_trib_calc_json, '$.IBSCBS.cClassTrib') = '200028');
    l_i := item(l_sim, 2);
    confere('Regime item 2: IS 15,00 sobre base 150 e vBC CBS/IBS 165', l_i.r_v_is = 15 and l_i.r_vbc_is = 150 and l_i.r_vbc = 165);
    l_i := item(l_sim, 4);
    confere('Regime item 4: INCONSISTENCIA_ENTRADA', l_i.estado_item = 'INCONSISTENCIA_ENTRADA');
    select max(e.mensagem_amigavel), count(*) into l_txt, l_qtd
      from simulacao_item_erro e
     where e.simulacao_id = l_sim and e.item_id = l_i.item_id and e.codigo = 'REG-011' and e.numero_item = 4;
    confere('Regime item 4: erro REG-011 ligado ao item 4', l_qtd = 1);
    confere('Regime item 4: mensagem amigável "Item 4, campo NCM: ..."', l_txt like 'Item 4, campo NCM: NCM não vinculada. NCM de código 02013000%(REG-011)');
    dbms_output.put_line('      -> ' || l_txt);

    -- duplicar e limpar
    l_qtd := pkg_rtc_calc.duplicar(l_sim);
    select count(*) into l_qtd from simulacao_item where simulacao_id = l_qtd and estado_item is null;
    confere('duplicar copia 4 itens sem resultado', l_qtd = 4);
    pkg_rtc_calc.limpar_resultado(l_sim);
    l_s := sim(l_sim);
    select count(*) into l_qtd from simulacao_item_erro where simulacao_id = l_sim;
    confere('limpar_resultado volta para RASCUNHO e apaga erros', l_s.status = 'RASCUNHO' and l_s.tot_cbs is null and l_qtd = 0);

    ----------------------------------------------------------------------------
    -- Regime Regular: ProblemDetail 422 (erro global)
    ----------------------------------------------------------------------------
    insert into simulacao (cliente_id, regime, versao_leiaute, dh_fato_gerador, uf, municipio_ibge)
    values (l_cli, 'REGULAR', '1.0.0', timestamp '2027-03-10 10:00:00 -03:00', 'RS', 9999999)
    returning simulacao_id into l_sim_422;
    insert into simulacao_item (simulacao_id, numero, cst, cclasstrib, base_calculo) values (l_sim_422, 1, '000', '000001', 10);
    pkg_rtc_calc.processar_problema(l_sim_422, 422, c_resp_422);
    l_s := sim(l_sim_422);
    confere('422: status REJEITADA com título e detalhe', l_s.status = 'REJEITADA'
            and l_s.mensagem_erro = 'Erros no processamento do cálculo: O cálculo contém 1 erro(s).');
    select max(mensagem_amigavel), count(*) into l_txt, l_qtd
      from simulacao_item_erro where simulacao_id = l_sim_422 and codigo = 'REG-020' and item_id is null;
    confere('422: erro global REG-020 sem item', l_qtd = 1);
    confere('422: mensagem do catálogo tem prioridade', l_txt = 'Operação: Confira a UF da operação. (REG-020)');

    ----------------------------------------------------------------------------
    -- Simples Nacional: montagem e leitura da resposta real
    ----------------------------------------------------------------------------
    insert into simulacao (cliente_id, regime, id_operacao, versao_leiaute, data_fato_gerador, tp_doc, crt)
    values (l_cli_sn, 'SIMPLES', '507f1f77bcf86cd799439011', '2.0.0', date '2027-03-15', 55, '1')
    returning simulacao_id into l_sim_sn;
    insert into simulacao_item (simulacao_id, numero, c_ativ_sn, cclasstrib, ncm, base_calculo, valor_is, p_ibs_sn, p_cbs_sn)
    values (l_sim_sn, 1, '01', '000001', '22030000', 950, 50, 1.25, 2.75);
    insert into simulacao_item (simulacao_id, numero, c_ativ_sn, cclasstrib, ncm, base_calculo, valor_is, p_ibs_sn, p_cbs_sn)
    values (l_sim_sn, 2, '99', '000001', '10063021', 100, 0, 1.25, 2.75);
    insert into simulacao_item (simulacao_id, numero, c_ativ_sn, cclasstrib, ncm, base_calculo, valor_is, p_ibs_sn, p_cbs_sn)
    values (l_sim_sn, 3, '01', '000001', '10063021', 100, 0, 1.25, 2.75);

    l_req := pkg_rtc_calc.montar_requisicao_simples(l_sim_sn);
    select count(*) into l_qtd from dual where json_equal(l_req, c_req_simples);
    confere('JSON do Simples igual ao esperado (strings 13v2, CRT e tpDoc texto)', l_qtd = 1);
    -- type() via SQL: o JSON_VALUE nativo do PL/SQL ignora o item method
    select count(*) into l_qtd from dual
     where json_value(l_req, '$.itens[0].baseCalculo.type()') = 'string'
       and json_value(l_req, '$.itens[0].baseCalculo') = '950.00';
    confere('Simples: baseCalculo como string "950.00"', l_qtd = 1);

    pkg_rtc_calc.processar_resposta_simples(l_sim_sn, c_resp_simples);
    l_s := sim(l_sim_sn);
    confere('Simples: status com pendências (2 de 3)', l_s.status = 'PROCESSADA_COM_PENDENCIAS' and l_s.qtd_itens_pendentes = 2);
    confere('Simples: totais RBSN 1050 / vBC 950 / IBS 11,88 / CBS 26,12 / IS 50 / tributos 88',
            l_s.tot_receita_bruta_sn = 1050 and l_s.tot_base_calculo = 950 and l_s.tot_ibs = 11.88
            and l_s.tot_cbs = 26.12 and l_s.tot_is = 50 and l_s.tot_tributos = 88);
    l_i := item(l_sim_sn, 1);
    confere('Simples item 1: CALCULADO, IBS 11,88, CBS 26,12, total 88', l_i.estado_item = 'CALCULADO'
            and l_i.r_v_ibs = 11.88 and l_i.r_v_cbs = 26.12 and l_i.r_total_item = 88 and l_i.r_tp_rbsn = 1);
    l_i := item(l_sim_sn, 2);
    confere('Simples item 2: NAO_CALCULADO com motivo CATIVSN_DESCONHECIDO',
            l_i.estado_item = 'NAO_CALCULADO' and l_i.motivo_estado_codigo = 'CATIVSN_DESCONHECIDO');
    select max(mensagem_amigavel) into l_txt from simulacao_item_erro where simulacao_id = l_sim_sn and codigo = 'VSN-051';
    confere('Simples item 3: VSN-051 "Item 3, campo NCM"', l_txt like 'Item 3, campo NCM: Formato de nomenclatura inválido.%');

    ----------------------------------------------------------------------------
    -- DANFSe: validação local do XML
    ----------------------------------------------------------------------------
    l_val := pkg_rtc_danfse.validar_xml(blob_de(
        '<?xml version="1.0" encoding="UTF-8"?><NFSe xmlns="http://www.sped.fazenda.gov.br/nfse" versao="1.01">'
     || '<infNFSe Id="NFS43149022211222333000181000000000012327010000000001"><nNFSe>123</nNFSe>'
     || '<dhProc>2027-01-10T10:00:00-03:00</dhProc><emit><CNPJ>11222333000181</CNPJ><xNome>Prestador Teste</xNome></emit>'
     || '<valores><vLiq>950.00</vLiq></valores><DPS><infDPS Id="DPS1"><dhEmi>2027-01-10T09:00:00-03:00</dhEmi>'
     || '<toma><CNPJ>11444777000161</CNPJ></toma></infDPS></DPS></infNFSe></NFSe>'));
    confere('DANFSe: NFS-e nacional aceita', l_val.valido and l_val.codigo = 'OK');
    confere('DANFSe: campos extraídos (nNFSe, emit, toma, vLiq, dhEmi)', l_val.numero_nfse = '123'
            and l_val.cnpj_emitente = '11222333000181' and l_val.cnpj_tomador = '11444777000161'
            and l_val.valor_liquido = '950.00' and l_val.dh_emissao = '2027-01-10T09:00:00-03:00'
            and l_val.chave_acesso like 'NFS4314%');
    l_val := pkg_rtc_danfse.validar_xml(blob_de(
        '<?xml version="1.0" encoding="UTF-8"?><CompNfse xmlns="http://www.abrasf.org.br/nfse.xsd"><Nfse><InfNfse Id="1"/></Nfse></CompNfse>'));
    confere('DANFSe: XML ABRASF recusado com mensagem amigável', not l_val.valido and l_val.codigo = 'XML_MUNICIPAL_ABRASF');
    dbms_output.put_line('      -> ' || l_val.mensagem);
    l_val := pkg_rtc_danfse.validar_xml(blob_de('<NFSe><infNFSe Id="X"/></NFSe>'));
    confere('DANFSe: <NFSe> sem namespace nacional recusado', not l_val.valido and l_val.codigo = 'XML_NAO_PADRAO_NACIONAL');
    l_val := pkg_rtc_danfse.validar_xml(blob_de('isto não é XML'));
    confere('DANFSe: arquivo não-XML recusado', not l_val.valido and l_val.codigo = 'XML_MAL_FORMADO');
    l_val := pkg_rtc_danfse.validar_xml(blob_de('<?xml version="1.0"?><!DOCTYPE foo SYSTEM "http://x/evil.dtd"><NFSe/>'));
    confere('DANFSe: DOCTYPE recusado', not l_val.valido and l_val.codigo = 'XML_MAL_FORMADO');
    l_val := pkg_rtc_danfse.validar_xml(empty_blob());
    confere('DANFSe: arquivo vazio recusado', not l_val.valido and l_val.codigo = 'ARQUIVO_VAZIO');

    ----------------------------------------------------------------------------
    pkg_ecloud_ctx.limpar_contexto;
    rollback to inicio_teste;
    if l_falhas = 0 then
        dbms_output.put_line('fase2_offline: SUCESSO');
    else
        raise_application_error(-20999, 'fase2_offline: ' || l_falhas || ' falha(s)');
    end if;
exception
    when others then
        pkg_ecloud_ctx.limpar_contexto;
        rollback to inicio_teste;
        raise;
end;
/
