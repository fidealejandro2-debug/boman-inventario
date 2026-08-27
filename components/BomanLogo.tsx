import Image from "next/image";

type BomanLogoProps = {
  className?: string;
  priority?: boolean;
};

export default function BomanLogo({ className, priority = false }: BomanLogoProps) {
  return (
    <Image
      src="/boman-logo.png"
      alt="Boman Sport"
      width={250}
      height={150}
      className={className}
      priority={priority}
    />
  );
}
