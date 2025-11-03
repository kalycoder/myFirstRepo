from app import create_app

app = create_app()

if __name__ == '__main__':
    app.run(port=55151, debug=True, host="0.0.0.0")
