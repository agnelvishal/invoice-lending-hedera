"""Builds demo/demo.mp4: python3 demo/make_video.py  (needs ffmpeg + Pillow)."""
import os, subprocess, sys
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.dirname(os.path.abspath(__file__))
FR = os.path.join(OUT, "frames"); os.makedirs(FR, exist_ok=True)
W, H = 1280, 720
BG, FG, MUTED, ACC, GOOD, WARN = (14,18,28), (235,240,250), (130,142,165), (88,166,255), (80,200,140), (255,170,80)
F = "/usr/share/fonts/truetype/dejavu/DejaVuSans%s.ttf"
def font(sz, bold=False): return ImageFont.truetype(F % ("-Bold" if bold else ""), sz)
MONO = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 22)

def canvas(title, step=None):
    im = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(im)
    d.rectangle([0,0,W,6], fill=ACC)
    d.text((60,50), title, font=font(40, True), fill=FG)
    if step: d.text((W-170,60), step, font=font(22), fill=MUTED)
    d.text((60,H-45), "Invoice Collateral Lending on Hedera  |  Asset Tokenization Studio + Stablecoin Studio", font=font(16), fill=MUTED)
    return im, d

def box(d, xy, label, sub, color):
    x,y,w,h = xy
    d.rounded_rectangle([x,y,x+w,y+h], 14, outline=color, width=3, fill=(22,28,42))
    d.text((x+20,y+14), label, font=font(24, True), fill=color)
    for i,l in enumerate(sub): d.text((x+20,y+56+i*30), l, font=font(20), fill=FG)

def arrow(d, a, b, label, color=MUTED):
    d.line([a,b], fill=color, width=4)
    ang = 1 if b[0]>a[0] else -1
    d.polygon([b,(b[0]-14*ang,b[1]-9),(b[0]-14*ang,b[1]+9)], fill=color)
    if a[0]==b[0]: d.text((a[0]+16,(a[1]+b[1])//2-12), label, font=font(18), fill=color)
    else: d.text(((a[0]+b[0])//2-len(label)*5,(a[1]+b[1])//2-34), label, font=font(18), fill=color)

scenes = []
def scene(im, secs): scenes.append((im, secs))

# 1 title
im,d = canvas("")
d.text((60,230), "Invoice Collateral Lending", font=font(64, True), fill=FG)
d.text((60,315), "on Hedera testnet", font=font(64, True), fill=ACC)
d.text((60,430), "SMEs lock tokenized invoices as collateral, borrow stablecoins,", font=font(28), fill=MUTED)
d.text((60,470), "and get collateral back automatically when the customer pays.", font=font(28), fill=MUTED)
scene(im, 4)

# 2 problem
im,d = canvas("The problem")
for i,t in enumerate(["SMEs wait 30-90 days to be paid on invoices.", "Cash is stuck; lenders can't verify or hold the collateral.", "Releasing collateral after payment is manual and slow."]):
    d.text((80,190+i*90), "-  "+t, font=font(30), fill=FG)
d.text((80,500), "Solution: on-chain escrow of the invoice token + automatic settlement.", font=font(30, True), fill=GOOD)
scene(im, 5)

# 3 building blocks
im,d = canvas("Building blocks")
box(d,(60,170,560,190),"Asset Tokenization Studio",["Invoice as a bond-type security token","KYC / allowlists, holds (escrow)","Hold = collateral lock, escrow-controlled"],ACC)
box(d,(660,170,560,190),"Stablecoin Studio",["HTS-based stablecoin","Used for lending and repayment","Roles, KYC, freeze, reserve proof"],ACC)
box(d,(60,400,1160,190),"InvoiceLending (custom contract)",["Lender pool with shares  |  loan requests that verify the ATS hold","Underwriter funding  |  payer-only payInvoice with automatic waterfall","Liquidation after due date + grace  |  risk parameters + pause"],GOOD)
scene(im, 6)

# 4-7 flow
def flow(step, title, hl, lines):
    im,d = canvas(title, step)
    box(d,(40,190,260,150),"SME",["invoice tokens","wants cash"],ACC if hl=="sme" else MUTED)
    box(d,(510,190,260,150),"InvoiceLending",["pool + escrow","settlement"],GOOD if hl=="loan" else MUTED)
    box(d,(980,190,260,150),"Lenders",["stablecoin pool",""],ACC if hl=="lend" else MUTED)
    box(d,(510,400,260,130),"Customer",["owes the invoice"],WARN if hl=="cust" else MUTED)
    return im,d
im,d = flow("1 / 4","1. Lenders fund the pool","lend",[])
arrow(d,(980,265),(770,265),"deposit 50,000 mUSD",ACC)
d.text((60,590),"Pool idle cash: 50,000   |   shares minted 1:1 for the first deposit", font=font(24), fill=FG)
scene(im,5)
im,d = flow("2 / 4","2. SME locks invoice, underwriter funds","sme",[])
arrow(d,(300,235),(510,235),"hold + requestLoan",ACC)
arrow(d,(510,305),(300,305),"8,000 mUSD",GOOD)
d.text((60,570),"Invoice face 10,000  |  max advance 80% -> principal 8,000  |  fee 3% = 240", font=font(24), fill=FG)
d.text((60,610),"The hold names the contract as escrow, so only the contract can release it.", font=font(22), fill=MUTED)
scene(im,6)
im,d = flow("3 / 4","3. Customer pays: automatic settlement","cust",[])
arrow(d,(640,400),(640,340),"pays 10,000",WARN)
arrow(d,(770,235),(980,235),"8,240 to lenders",GOOD)
arrow(d,(510,305),(300,305),"1,760 surplus",GOOD)
d.text((60,570),"Collateral hold is released in the same transaction. Pool: 50,000 -> 50,240.", font=font(24), fill=GOOD)
scene(im,6)
im,d = flow("4 / 4","4. If nobody pays: liquidation","loan",[])
d.text((60,380),"After due date + 3 days grace, anyone can call liquidate():", font=font(24), fill=FG)
d.text((60,420),"-  the ATS hold is executed to the collateral receiver", font=font(24), fill=WARN)
d.text((60,458),"-  unrecovered principal is written off against the pool", font=font(24), fill=WARN)
d.text((60,496),"Example test: 1,000 repaid of 8,000 -> 7,000 written off, pool 43,000", font=font(24), fill=MUTED)
scene(im,6)

# 8 real tests
tests = open(os.environ.get("TESTS","/tmp/tests.txt")).read().splitlines() if os.path.exists(os.environ.get("TESTS","/tmp/tests.txt")) else []
im,d = canvas("Live test run (real output)")
d.rounded_rectangle([60,130,W-60,H-80],12,fill=(8,10,16),outline=MUTED,width=2)
d.text((85,145),"$ pnpm test   (contracts/)", font=MONO, fill=MUTED)
y=185
for l in tests:
    c = GOOD if "✔" in l else FG
    l = l.replace("✔","[ok]")
    d.text((85,y), l[:105], font=ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",17), fill=c); y+=34
scene(im,7)

# 9 status
im,d = canvas("Status and next steps")
rows=[("Loan contract + 9 unit tests","done",GOOD),("ATS contracts on testnet","deploy paused at step 3/9",WARN),("Stablecoin Studio token on testnet","next",MUTED),("End-to-end run on testnet","next",MUTED),("Backend indexer + web app","planned",MUTED)]
for i,(a,b,c) in enumerate(rows):
    d.text((80,190+i*70),a,font=font(28),fill=FG); d.text((700,190+i*70),b,font=font(28,True),fill=c)
d.text((80,590),"github.com/agnelvishal/invoice-lending-hedera", font=font(26,True), fill=ACC)
d.text((80,630),"Demo uses unit tests with mocked ATS holds; no mainnet funds involved.", font=font(20), fill=MUTED)
scene(im,6)

# render
lst=[]
for i,(im,secs) in enumerate(scenes):
    p=os.path.join(FR,f"s{i}.png"); im.save(p); lst.append((p,secs))
with open(os.path.join(FR,"list.txt"),"w") as f:
    for p,s in lst: f.write(f"file '{p}'\nduration {s}\n")
    f.write(f"file '{lst[-1][0]}'\n")
out=os.path.join(OUT,"demo.mp4")
subprocess.run(["ffmpeg","-y","-loglevel","error","-f","concat","-safe","0","-i",os.path.join(FR,"list.txt"),
  "-vf","fps=30,format=yuv420p,fade=t=in:st=0:d=0.5","-c:v","libx264","-crf","23",out],check=True)
print(out, sum(s for _,s in lst),"s")
