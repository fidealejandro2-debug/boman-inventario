import type { Metadata } from "next";
import "./globals.css";
import ConexionEstado from "@/components/ConexionEstado";

export const metadata: Metadata = {
  title: "Boman Sport — Inventario",
  description: "Sistema de inventario de producto terminado",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="es">
      <body><ConexionEstado />{children}</body>
    </html>
  );
}
