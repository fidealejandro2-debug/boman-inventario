import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";

export type Perfil = {
  id: string;
  nombre_completo: string;
  rol: "admin" | "bodega" | "logistica" | "gerencia";
  entidad_id: string | null;
  activo: boolean;
};

export async function getPerfilActual(): Promise<Perfil> {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: perfil } = await supabase
    .from("perfiles")
    .select("id, nombre_completo, rol, entidad_id, activo")
    .eq("id", user.id)
    .single();

  if (!perfil) redirect("/login");

  return perfil as Perfil;
}
