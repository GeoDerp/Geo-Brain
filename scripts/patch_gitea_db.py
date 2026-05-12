import sqlite3, json, sys
db_path = sys.argv[1]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("SELECT cfg FROM login_source WHERE name='kanidm';")
row = cur.fetchone()
if row:
    cfg = json.loads(row[0])
    cfg["Scopes"] = ["openid", "profile", "email", "groups"]
    # Gitea's field name for username claim mapping is "GroupName" or handled via --user-id-claim
    # Actually, in the JSON it's often not there and needs to be set via CLI properly.
    # But we can try to inject it if we know the key.
    # We will also allow dots and unicode in the app.ini which we already did.
    conn.execute("UPDATE login_source SET cfg=? WHERE name='kanidm';", (json.dumps(cfg),))
    conn.commit()
    print("Patched Gitea OIDC scopes in DB")
else:
    print("Kanidm auth source not found in DB")
conn.close()
