export const dynamic = "force-dynamic";

import { createClient } from "@/lib/supabase/server";
import { getPerfilActual } from "@/lib/getPerfil";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";

export default async function ReportesPage() {
  const perfil = await getPerfilActual();
  if (perfil.rol !== "admin" && perfil.rol !== "gerencia") redirect("/dashboard");

  const supabase = createClient();
  const { data: inventario } = await supabase
    .from("inventario")
    .select("cantidad, productos(categoria), entidades(nombre)");

  const porEntidad: Record<string, number> = {};
  const porCategoria: Record<string, number> = {};

  (inventario ?? []).forEach((r: any) => {
    const ent = r.entidades?.nombre ?? "Sin entidad";
    const cat = r.productos?.categoria ?? "Sin categoría";
    porEntidad[ent] = (porEntidad[ent] ?? 0) + r.cantidad;
    porCategoria[cat] = (porCategoria[cat] ?? 0) + r.cantidad;
  });

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <h2 style={{ color: "#1f3864" }}>Reportes</h2>

        <div className="grid-2">
          <div className="card">
            <h3 style={{ marginTop: 0 }}>Stock por entidad</h3>
            <table>
              <thead><tr><th>Entidad</th><th>Unidades</th></tr></thead>
              <tbody>
                {Object.entries(porEntidad).map(([nombre, cant]) => (
                  <tr key={nombre}><td>{nombre}</td><td>{cant}</td></tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="card">
            <h3 style={{ marginTop: 0 }}>Stock por categoría</h3>
            <table>
              <thead><tr><th>Categoría</th><th>Unidades</th></tr></thead>
              <tbody>
                {Object.entries(porCategoria).map(([nombre, cant]) => (
                  <tr key={nombre}><td>{nombre}</td><td>{cant}</td></tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </>
  );
}
