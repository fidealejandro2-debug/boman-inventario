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
