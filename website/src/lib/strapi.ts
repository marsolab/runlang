const STRAPI_URL = import.meta.env.STRAPI_URL || "http://localhost:1337";
const STRAPI_TOKEN = import.meta.env.STRAPI_TOKEN || "";

interface StrapiImage {
  url: string;
  alternativeText: string | null;
  width: number;
  height: number;
}

export interface StrapiPost {
  id: number;
  documentId: string;
  title: string;
  slug: string;
  description: string;
  content: string;
  publishedAt: string;
  cover?: StrapiImage;
  author?: {
    name: string;
    avatar?: StrapiImage;
  };
  category?: {
    name: string;
    slug: string;
  };
}

interface StrapiResponse<T> {
  data: T;
  meta: {
    pagination?: {
      page: number;
      pageSize: number;
      pageCount: number;
      total: number;
    };
  };
}

async function fetchStrapi<T>(
  endpoint: string,
  params: Record<string, string> = {},
): Promise<StrapiResponse<T>> {
  const url = new URL(`/api${endpoint}`, STRAPI_URL);
  for (const [key, value] of Object.entries(params)) {
    url.searchParams.set(key, value);
  }

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
  if (STRAPI_TOKEN) {
    headers.Authorization = `Bearer ${STRAPI_TOKEN}`;
  }

  const res = await fetch(url.toString(), { headers });
  if (!res.ok) {
    throw new Error(`Strapi error ${res.status}: ${res.statusText}`);
  }
  return res.json();
}

export async function getPosts(
  page = 1,
  pageSize = 10,
): Promise<StrapiResponse<StrapiPost[]>> {
  return fetchStrapi<StrapiPost[]>("/articles", {
    "populate": "*",
    "sort": "publishedAt:desc",
    "pagination[page]": String(page),
    "pagination[pageSize]": String(pageSize),
  });
}

export async function getPostBySlug(
  slug: string,
): Promise<StrapiPost | null> {
  const response = await fetchStrapi<StrapiPost[]>("/articles", {
    "populate": "*",
    "filters[slug][$eq]": slug,
  });
  return response.data[0] ?? null;
}

export async function getCategories(): Promise<
  StrapiResponse<{ name: string; slug: string }[]>
> {
  return fetchStrapi<{ name: string; slug: string }[]>("/categories", {
    populate: "*",
  });
}

export function strapiImageUrl(image?: StrapiImage): string | null {
  if (!image?.url) return null;
  if (image.url.startsWith("http")) return image.url;
  return `${STRAPI_URL}${image.url}`;
}
