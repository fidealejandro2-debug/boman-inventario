const trazos: Record<string, string> = {
  inventario: "m12 3 9 5-9 5-9-5 9-5Zm-9 9 9 5 9-5M3 16l9 5 9-5M12 13v8",
  operaciones: "M4 7h15m-4-4 4 4-4 4M20 17H5m4-4-4 4 4 4",
  ventas: "M3 4h2l3 12h11l2-8H6M9 20h.01M18 20h.01",
  compras: "M5 8h14l1 13H4L5 8Zm3 0V6a4 4 0 0 1 8 0v2",
  tesoreria: "M3 7h18v14H3V7Zm0 0 14-4v4M16 12h5v5h-5v-5Z",
  produccion: "M3 21V10l6 3V7l6 3V3h6v18H3Zm4-4h1m4 0h1m4 0h1",
  franquicia: "M3 10 5 3h14l2 7M4 10v11h16V10M9 21v-7h6v7M3 10a3 3 0 0 0 6 0 3 3 0 0 0 6 0 3 3 0 0 0 6 0",
  mantenimiento: "m14 6 4 4 3-3a7 7 0 0 1-9 9l-6 6-4-4 6-6a7 7 0 0 1 9-9l-3 3Z",
  nomina: "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M16 4a4 4 0 0 1 0 8m6 9v-2a4 4 0 0 0-3-4M13 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z",
  reportes: "M4 3v18h17M8 16v-5m5 5V7m5 9V4",
  administracion: "M12 3 3 7v6c0 5 9 9 9 9s9-4 9-9V7l-9-4Zm-4 9 3 3 5-6",
  notificaciones: "M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4",
  contratos: "M14 2H4v20h16V8l-6-6Zm0 0v6h6M8 12h8m-8 4h6",
  importar: "M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5",
  flecha: "M5 12h14m-6-6 6 6-6 6",
  actualizar: "M20 7v5h-5M4 17v-5h5M6 6a8 8 0 0 1 13 2M5 16a8 8 0 0 0 13 2",
  reloj: "M12 8v4l3 2M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z",
};

export default function IconoPanel({ nombre, className }: { nombre: string; className?: string }) {
  return <svg className={className} width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={trazos[nombre] ?? trazos.inventario} /></svg>;
}
