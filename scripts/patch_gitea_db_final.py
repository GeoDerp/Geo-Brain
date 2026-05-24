import sqlite3, json, sys
db_path = sys.argv[1]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("SELECT cfg FROM login_source WHERE name='kanidm';")
row = cur.fetchone()
if row:
    cfg = json.loads(row[0])
    # For Gitea 1.21.x, we can try to force the UserID to map to sub
    # But usually Gitea uses sub as the external identifier.
    # The problem is the local username creation.
    # We will try to map "nickname" or "sub" if available.
    # In Gitea OIDC provider, Scopes are used.
    cfg["Scopes"] = ["openid", "profile", "email", "groups"]
    conn.execute("UPDATE login_source SET cfg=? WHERE name='kanidm';", (json.dumps(cfg),))
    conn.commit()
    print("Patched Gitea OIDC config in DB")
else:
    print("Kanidm auth source not found in DB")
conn.close()
