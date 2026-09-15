// Catálogo canónico usado al editar prendas ya importadas. Se mantiene fuera
// del formulario de ingreso para que las pantallas de producción no dependan
// de un componente cliente grande ni de cambios que todavía estén en curso.
export const PRENDAS_CONTRATO = [
  "Camiseta Jugador", "Camiseta Jugador M/L", "Pantaloneta Jugador",
  "Camiseta Arquero", "Camiseta Arquero M/L", "Pantaloneta Arquero",
  "Arquero Completo", "Uniformes Completos", "Camiseta Polo",
  "Camiseta Polo M/L", "Chompa", "Pantalón", "Exterior Completo",
  "Rompevientos", "Chompa de Frío", "Chompa Frío 3/4", "Chompas Retro",
  "Chompa Deportiva", "Hoodie", "Buzo de Compresión", "Chaleco", "Medias",
  "Bandera", "Cinta Capitán", "Bermudas", "Falda Short", "Licra", "Bolsos",
  "BVDS",
] as const;

export const CALIDADES_CONTRATO = [
  "Semiprofesional", "Competición", "Profesional", "Amateur", "Estándar",
] as const;

export const TALLAS_ADULTOS_CONTRATO = [
  "XS", "S", "M", "L", "XL", "2XL", "3XL", "4XL",
] as const;

// XXS (14) continua la escala infantil despues de 36 (12). Mantener el texto
// completo: es la clave que comparten nomina, matriz de tallas e imprimible.
export const TALLAS_NINOS_CONTRATO = [
  "24 (0)", "26 (2)", "28 (4)", "30 (6)", "32 (8)", "34 (10)",
  "36 (12)", "XXS (14)",
] as const;
