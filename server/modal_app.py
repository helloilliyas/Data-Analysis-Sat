"""Modal deployment wrapper.

One-time setup:
    pip install modal
    modal setup                       # authenticate
    modal secret create satellite-api API_KEY=<pick-a-long-random-string>

Deploy:
    modal deploy modal_app.py

Modal prints the public URL, e.g.
    https://<workspace>--satellite-processor-web.modal.run
Enter that URL and the API key in the app's Settings screen.
"""

import modal

image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install(
        "fastapi==0.115.*",
        "pystac-client==0.8.*",
        "rasterio==1.4.*",
        "pyproj==3.7.*",
        "numpy==2.*",
        "pillow==11.*",
    )
    .add_local_python_source("app")
)

app = modal.App("satellite-processor", image=image)


@app.function(
    secrets=[modal.Secret.from_name("satellite-api")],
    timeout=120,
    memory=1024,
)
@modal.asgi_app()
def web():
    from app.main import create_app

    return create_app()
