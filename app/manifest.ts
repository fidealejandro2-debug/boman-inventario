import type { MetadataRoute } from "next";

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "Boman Sport Inventario",
    short_name: "Boman Inventario",
    description: "Operación multialmacén de Boman Sport",
    start_url: "/dashboard",
    display: "standalone",
    background_color: "#f4f7fb",
    theme_color: "#1f3864",
    lang: "es-EC",
    icons: [
      {
        src: "/boman-logo.png",
        sizes: "250x150",
        type: "image/png",
        purpose: "any",
      },
    ],
  };
}
