export const dynamic = "force-dynamic";

import { getPerfilActual } from "@/lib/getPerfil";
import { redirect } from "next/navigation";

export default async function ImportarPage() {
  await getPerfilActual();
  redirect("/conteos");
}
