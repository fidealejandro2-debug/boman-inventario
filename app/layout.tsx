import type { Metadata } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import "./globals.css";
import ConexionEstado from "@/components/ConexionEstado";
import DialogoAnfitrion from "@/components/Dialogo";
import ThemeToggle from "@/components/ThemeToggle";

const scriptTema = `(function(){
  try {
    var t = localStorage.getItem('boman-tema');
    if (t !== 'light' && t !== 'dark') {
      t = matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    }
    document.documentElement.setAttribute('data-theme', t);
  } catch (e) {}
})();`;

export const metadata: Metadata = {
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL ?? "https://boman-inventario.vercel.app"),
  title: "Boman Sport — Inventario",
  description: "Sistema de inventario de producto terminado",
  icons: {
    icon: [{ url: "/boman-logo.png", type: "image/png" }],
    apple: [{ url: "/boman-logo.png", type: "image/png" }],
  },
  openGraph: {
    title: "Boman Sport — Inventario",
    description: "Sistema de inventario de producto terminado",
    images: [{ url: "/boman-logo.png", width: 250, height: 150, alt: "Boman Sport" }],
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="es" className={`${GeistSans.variable} ${GeistMono.variable}`}>
      <head>
        <script dangerouslySetInnerHTML={{ __html: scriptTema }} />
      </head>
      <body className={GeistSans.className}>
        <ThemeToggle />
        <ConexionEstado /><DialogoAnfitrion />{children}
      </body>
    </html>
  );
}
