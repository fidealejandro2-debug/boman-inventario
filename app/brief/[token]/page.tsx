import BriefPublicoCliente from "./BriefPublicoCliente";

export default function BriefPublicoPage({params}:{params:{token:string}}){
  return <BriefPublicoCliente token={params.token}/>;
}
