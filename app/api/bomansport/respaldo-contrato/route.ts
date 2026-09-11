import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";

export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return NextResponse.json({ ok:false, error:"Sesión requerida" },{status:401});
  const body = await request.json().catch(()=>null) as { contrato_id?:string }|null;
  if (!body?.contrato_id) return NextResponse.json({ok:false,error:"Falta el contrato"},{status:400});
  const admin=createAdminClient();
  const {data:perfil}=await admin.from("perfiles").select("rol,activo").eq("id",auth.user.id).maybeSingle();
  const {data:ingreso}=await admin.from("contrato_ingresos_v108").select("id,usuario_id").eq("contrato_id",body.contrato_id).maybeSingle();
  if(!perfil?.activo||!ingreso||(ingreso.usuario_id!==auth.user.id&&perfil.rol!=="admin"))return NextResponse.json({ok:false,error:"No autorizado"},{status:403});
  const base=process.env.BOMANSPORT_WEBAPP_URL,token=process.env.BOMANSPORT_API_TOKEN;
  if(!base||!token)return NextResponse.json({ok:false,pendiente:true,error:"Faltan BOMANSPORT_WEBAPP_URL o BOMANSPORT_API_TOKEN"},{status:503});
  const tablas=["contrato_prendas","contrato_jugadores","contrato_archivos","contrato_specs","contrato_facturacion"] as const;
  const {data:contrato,error}=await admin.from("contratos").select("*").eq("id",body.contrato_id).single();
  if(error)return NextResponse.json({ok:false,error:error.message},{status:404});
  // Compatibilidad con la hoja histórica: su campo `cliente` en realidad
  // representa el nombre del contrato. El cliente real queda preservado con
  // nombre explícito dentro del JSON, incluso si Apps Script aún no se actualiza.
  const detalle:Record<string,unknown>={contrato:{...contrato,cliente_real_v115:contrato.cliente,cliente:contrato.nombre_contrato_v115||contrato.cliente}};
  for(const tabla of tablas){const r=await admin.from(tabla).select("*").eq("contrato_id",body.contrato_id);if(r.error)return NextResponse.json({ok:false,error:r.error.message},{status:500});detalle[tabla]=r.data??[]}
  try{
    const respuesta=await fetch(`${base}?api=respaldo-contrato&token=${encodeURIComponent(token)}`,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(detalle),cache:"no-store"});
    const texto=await respuesta.text();let remoto:any;try{remoto=JSON.parse(texto)}catch{throw new Error(`Apps Script devolvió una respuesta inválida (${respuesta.status})`)}
    if(!respuesta.ok||!remoto?.ok)throw new Error(remoto?.error||`Apps Script respondió ${respuesta.status}`);
    await admin.from("contrato_ingresos_v108").update({respaldo_sheets_estado:"sincronizado",respaldo_sheets_intentos:1,respaldo_sheets_error:null,respaldado_sheets_at:new Date().toISOString()}).eq("id",ingreso.id);
    return NextResponse.json({ok:true,url:remoto.url||null});
  }catch(e){const mensaje=e instanceof Error?e.message:"No se pudo respaldar";await admin.from("contrato_ingresos_v108").update({respaldo_sheets_estado:"error",respaldo_sheets_error:mensaje}).eq("id",ingreso.id);return NextResponse.json({ok:false,pendiente:true,error:mensaje},{status:502})}
}
