export function redondearCentavos(valor: number) {
  return Math.round((valor + Number.EPSILON) * 100) / 100;
}

export function diferenciaPagos(total: number, pagos: Array<number | string | null | undefined>) {
  const pagado = pagos.reduce<number>((suma, pago) => suma + Number(pago || 0), 0);
  return redondearCentavos(pagado - Number(total || 0));
}

export function calcularCierreCaja({
  saldoInicial,
  ingresosEfectivo,
  egresosEfectivo,
  efectivoContado,
}: {
  saldoInicial: number;
  ingresosEfectivo: number;
  egresosEfectivo: number;
  efectivoContado: number;
}) {
  const saldoEsperado = redondearCentavos(
    Number(saldoInicial || 0) + Number(ingresosEfectivo || 0) - Number(egresosEfectivo || 0)
  );
  return {
    saldoEsperado,
    diferencia: redondearCentavos(Number(efectivoContado || 0) - saldoEsperado),
  };
}

export function calcularStockOperativo({
  fisico,
  reservado,
  transitoEntrada,
  puntoReposicion,
  stockMaximo,
}: {
  fisico: number;
  reservado: number;
  transitoEntrada: number;
  puntoReposicion: number;
  stockMaximo: number;
}) {
  const disponible = Math.max(Math.trunc(fisico) - Math.trunc(reservado), 0);
  const posicion = disponible + Math.max(Math.trunc(transitoEntrada), 0);
  return {
    disponible,
    sugeridoReponer: posicion <= Math.trunc(puntoReposicion)
      ? Math.max(Math.trunc(stockMaximo) - posicion, 0)
      : 0,
  };
}

export function normalizarBeneficiosNomina({
  afiliado,
  decimoTercero,
  decimoCuarto,
  fondosMensual,
}: {
  afiliado: boolean;
  decimoTercero: boolean;
  decimoCuarto: boolean;
  fondosMensual: boolean;
}) {
  return {
    decimoTercero: afiliado && decimoTercero,
    decimoCuarto: afiliado && decimoCuarto,
    // La columna histórica usa true como valor neutro para no afiliados; el
    // cálculo SQL v129 ignora siempre el fondo cuando afiliado=false.
    fondosMensual: afiliado ? fondosMensual : true,
  };
}
