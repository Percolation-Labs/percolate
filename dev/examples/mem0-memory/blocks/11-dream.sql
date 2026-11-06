select key, value from jsonb_each(aiq.dream() - 'since' - 'until') order by key;
