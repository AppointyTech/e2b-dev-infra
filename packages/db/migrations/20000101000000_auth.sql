-- +goose Up
-- +goose StatementBegin
CREATE SCHEMA IF NOT EXISTS auth;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated;
    END IF;
END
$$;

CREATE FUNCTION auth.uid() RETURNS uuid AS $func$
BEGIN
    RETURN gen_random_uuid();
END;
$func$ LANGUAGE plpgsql;

-- Grant execute on auth.uid() to postgres role
GRANT EXECUTE ON FUNCTION auth.uid() TO postgres;

CREATE TABLE auth.users (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    email text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    raw_app_meta_data jsonb,
    raw_user_meta_data jsonb,
    PRIMARY KEY (id)
);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- +goose StatementEnd
