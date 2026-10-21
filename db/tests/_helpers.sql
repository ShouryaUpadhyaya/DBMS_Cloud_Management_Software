-- Test helpers, prepended to every test file by run.sh. Plain DO-blocks that RAISE on failure.
-- Each test file runs inside one transaction that is rolled back, so tests never leave data.
CREATE FUNCTION pg_temp.assert(p_cond boolean, p_msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'ASSERTION FAILED: %', p_msg; END IF;
END $$;

-- Runs p_sql in a subtransaction and checks that it fails with p_sqlstate (or any error if NULL).
-- The sub-block is a savepoint, so the failed statement does not abort the surrounding test.
CREATE FUNCTION pg_temp.expect_error(p_sql text, p_sqlstate text, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_state text;
  v_text text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_text = MESSAGE_TEXT;
    IF p_sqlstate IS NOT NULL AND v_state <> p_sqlstate THEN
      RAISE EXCEPTION 'ASSERTION FAILED: % (expected %, got % "%")', p_msg, p_sqlstate, v_state, v_text;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'ASSERTION FAILED: % (statement succeeded but should have failed)', p_msg;
END $$;

-- Same, but also checks the error message contains p_like.
CREATE FUNCTION pg_temp.expect_message(p_sql text, p_like text, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_text text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    IF v_text NOT LIKE p_like THEN
      RAISE EXCEPTION 'ASSERTION FAILED: % (message "%" does not match "%")', p_msg, v_text, p_like;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'ASSERTION FAILED: % (statement succeeded but should have failed)', p_msg;
END $$;

-- Ids that tests need from the seed.
CREATE FUNCTION pg_temp.uid(p_email text) RETURNS integer LANGUAGE sql AS
  $$ SELECT user_id FROM users WHERE email = p_email $$;
CREATE FUNCTION pg_temp.pid(p_name text) RETURNS integer LANGUAGE sql AS
  $$ SELECT project_id FROM projects WHERE name = p_name $$;
CREATE FUNCTION pg_temp.rid(p_name text) RETURNS integer LANGUAGE sql AS
  $$ SELECT resource_id FROM resources WHERE name = p_name $$;
